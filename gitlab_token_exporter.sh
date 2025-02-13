#!/bin/bash

############################################################################################################################
###                                            СБОР МЕТРИК ПО ТОКЕНАМ                                                    ###
############################################################################################################################

# Конфигурация
GITLAB_URL="https://gitlab.example.ru"
API_TOKEN="your-access-token"

# Время начала работы скрипта
start_time=$(date +%s)

# Функция для получения логина пользователя
get_user_login() {
    local user_id="$1"
    curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$GITLAB_URL/api/v4/users/$user_id" | jq -r '.username // "unknown_user"'
}

# Функция для получения имени проекта
get_project_name() {
    local project_id="$1"
    curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$GITLAB_URL/api/v4/projects/$project_id" | jq -r '.name // "unknown_project"'
}

# Функция для получения имени группы
get_group_name() {
    local groups_id="$1"
    curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$GITLAB_URL/api/v4/groups/$groups_id" | jq -r '.name // "unknown_project"'
}

######################################################################################
###                     РАБОТА С ПЕРСОНАЛЬНЫМИ ТОКЕННАМИ                           ###
######################################################################################

# Функция для обработки персональных токенов
# 1. Отправляет запросы на указанный URL (параметр url) с пагинацией.
# 2. Получает информацию о токенах.
# 3. Извлекает метрики:
#    - Имя токена.
#    - Тип токена (personal / project).
#    - Владелец (логин пользователя).
#    - Дату истечения срока действия токена.
#    - Дату последнего использования токена.
# 4. Вычисляеn количество дней до истечения срока действия токена
# 5. Выводит метрики в формате Prometheus:
#    - name — имя токена.
#    - type — тип токена (всегда personal).
#    - owner — владельц.
#    - last_used — дата последнего использования токена.
process_tokens() {
    local url="$1"
    local token_type="$2"
    local owner_type="$3"
    local paginate="$4"  # Флаг, нужна ли пагинация

    page=1
    while :; do
        # Формируем URL в зависимости от необходимости пагинации
        if [[ "$paginate" == "yes" ]]; then
            response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$url&page=$page&per_page=100")
        else
            response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$url")
        fi

        # Проверяем, является ли ответ массивом JSON
        token_count=$(echo "$response" | jq 'if type=="array" then length else empty end')

        # Если ответ некорректный или пустой — выходим
        [[ -z "$token_count" || "$token_count" -eq 0 ]] && break

        # Обрабатываем токены
        echo "$response" | jq -c '.[]' | while read -r token_info; do
            token_name=$(echo "$token_info" | jq -r '.name // empty')
            token_expiry=$(echo "$token_info" | jq -r '.expires_at // empty')
            last_used_at=$(echo "$token_info" | jq -r '.last_used_at // "never_used"')

            # Определяем владельца токена
            if [[ "$owner_type" == "user" ]]; then
                user_id=$(echo "$token_info" | jq -r '.user_id')
                token_owner=$(get_user_login "$user_id")
            else
                project_id=$(echo "$token_info" | jq -r '.project_id')
                token_owner=$(get_project_name "$project_id")
            fi

            # Пропускаем некорректные записи
            [[ -z "$token_name" || -z "$token_owner" ]] && continue

            # Вычисляем количество дней до истечения срока действия токена
            if [[ -n "$token_expiry" && "$token_expiry" != "null" ]]; then
                expiry_date=$(date -d "$token_expiry" +%s)
                current_date=$(date +%s)
                expiry_days=$(( ($expiry_date - $current_date) / 86400 ))
            else
                expiry_days=9999
            fi

            # Вывод метрики
            echo "gitlab_token_expiry_days{name=\"$token_name\", type=\"$token_type\", owner=\"$token_owner\", last_used=\"$last_used_at\"} $expiry_days"
        done

        # Если пагинация не нужна — выходим сразу
        [[ "$paginate" != "yes" ]] && break

        # Переход на следующую страницу (для персональных токенов)
        page=$((page + 1))
    done
}

# Получение данных о персональных токенах с обработкой пагинации
personal_tokens_url="$GITLAB_URL/api/v4/personal_access_tokens?active=true"
process_tokens "$personal_tokens_url" "personal" "user" "yes"

######################################################################################
###                       РАБОТА С ПРОЕКТНЫМИ ТОКЕННАМИ                            ###
######################################################################################
# Получение ID всех проектов с пагинацией
all_project_ids=()
page=1
while :; do
    projects_url="$GITLAB_URL/api/v4/projects?page=$page&per_page=100"
    projects_response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$projects_url")

    # Проверяем, является ли ответ массивом JSON
    project_count=$(echo "$projects_response" | jq 'if type=="array" then length else empty end')

    # Если проектов больше нет — выходим
    [[ -z "$project_count" || "$project_count" -eq 0 ]] && break

    # Добавляем ID проектов в массив
    while IFS= read -r project_id; do
        all_project_ids+=("$project_id")
    done < <(echo "$projects_response" | jq -r '.[].id')

    # Переход на следующую страницу
    page=$((page + 1))
done

# Обрабатываем проектные токены
for project_id in "${all_project_ids[@]}"; do
    project_tokens_url="$GITLAB_URL/api/v4/projects/$project_id/access_tokens"

    # Запрашиваем токены проекта
    tokens_response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$project_tokens_url")

    # Если токенов нет — пропускаем проект
    if [[ "$tokens_response" == "[]" ]]; then
        continue
    fi

    # Получаем имя проекта
    project_name=$(get_project_name "$project_id")

    # Обрабатываем токены, передавая имя проекта как owner
    echo "$tokens_response" | jq -c '.[]' | while read -r token_info; do
        token_name=$(echo "$token_info" | jq -r '.name // empty')
        token_expiry=$(echo "$token_info" | jq -r '.expires_at // empty')
        last_used_at=$(echo "$token_info" | jq -r '.last_used_at // "never_used"')

        # Пропускаем некорректные записи
        [[ -z "$token_name" || -z "$project_name" ]] && continue

        # Вычисляем количество дней до истечения срока действия токена
        if [[ -n "$token_expiry" && "$token_expiry" != "null" ]]; then
            expiry_date=$(date -d "$token_expiry" +%s)
            current_date=$(date +%s)
            expiry_days=$(( ($expiry_date - $current_date) / 86400 ))
        else
            expiry_days=9999
        fi

        # Вывод метрики с правильным owner
        echo "gitlab_token_expiry_days{name=\"$token_name\", type=\"project\", owner=\"$project_name\", last_used=\"$last_used_at\"} $expiry_days"
    done
done

######################################################################################
###                       РАБОТА С ГРУППОВЫМИ ТОКЕННАМИ                            ###
######################################################################################
# Получение ID всех групп с пагинацией
all_groups_ids=()
page=1
while :; do
    group_url="$GITLAB_URL/api/v4/groups?page=$page&per_page=100"
    group_response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$group_url")

    # Проверяем, является ли ответ массивом JSON
    groups_count=$(echo "$group_response" | jq 'if type=="array" then length else empty end')

    # Если групп больше нет — выходим
    [[ -z "$groups_count" || "$groups_count" -eq 0 ]] && break

    # Добавляем ID группы в массив
    while IFS= read -r groups_id; do
        all_groups_ids+=("$groups_id")
    done < <(echo "$group_response" | jq -r '.[].id')

    # Переход на следующую страницу
    page=$((page + 1))
done

# Обрабатываем групповые токены
for groups_id in "${all_groups_ids[@]}"; do
    page=1
    while :; do
        groups_tokens_url="$GITLAB_URL/api/v4/groups/$groups_id/access_tokens?page=$page&per_page=100"
        tokens_response=$(curl --silent --header "PRIVATE-TOKEN: $API_TOKEN" "$groups_tokens_url")

        # Проверяем, является ли ответ массивом JSON
        token_count=$(echo "$tokens_response" | jq 'if type=="array" then length else empty end')

        # Если токенов нет — выходим из цикла
        [[ -z "$token_count" || "$token_count" -eq 0 ]] && break

        # Получаем имя группы
        groups_name=$(get_group_name "$groups_id")

        # Обрабатываем токены, передавая имя группы как owner
        echo "$tokens_response" | jq -c '.[]' | while read -r token_info; do
            token_name=$(echo "$token_info" | jq -r '.name // empty')
            token_expiry=$(echo "$token_info" | jq -r '.expires_at // empty')
            last_used_at=$(echo "$token_info" | jq -r '.last_used_at // "never_used"')

            # Пропускаем некорректные записи
            [[ -z "$token_name" || -z "$groups_name" ]] && continue

            # Вычисляем количество дней до истечения срока действия токена
            if [[ -n "$token_expiry" && "$token_expiry" != "null" ]]; then
                expiry_date=$(date -d "$token_expiry" +%s)
                current_date=$(date +%s)
                expiry_days=$(( ($expiry_date - $current_date) / 86400 ))
            else
                expiry_days=9999
            fi

            # Вывод метрики с правильным owner
            echo "gitlab_token_expiry_days{name=\"$token_name\", type=\"groups\", owner=\"$groups_name\", last_used=\"$last_used_at\"} $expiry_days"
        done

        # Переход на следующую страницу
        page=$((page + 1))
    done
done

######################################################################################
###                           ВРЕМЯ РАБОТЫ СКРИПТА                                 ###
######################################################################################
end_time=$(date +%s)
execution_time=$((end_time - start_time))
echo "gitlab_token_script_time{name="gitlab_token_script_time", type="script"} $execution_time"

############################################################################################################################
###                                                 ПРИМЕЧАНИЯ                                                           ###
############################################################################################################################

##-------------------------------------------------- переменные ----------------------------------------------------------##
##-- Конфигурационные переменные:
# GITLAB_URL — Базовый URL GitLab-репозитория для отправки API-запросов.
# API_TOKEN — Персональный токен доступа для аутентификации и выполнения запросов к API GitLab.

##-- Локальные переменные:
# user_id — ID пользователя, которому принадлежит токен, извлекается из ответа API.
# token_name — Имя токена (персонального, проектного или группового), извлекается из ответа API.
# token_expiry — Дата истечения срока действия токена. Если токен бессрочный, возвращается null.
# token_owner — Логин пользователя, название проекта или группы в зависимости от типа токена.
# expiry_date — Дата истечения срока действия токена в формате UNIX-времени (секунды).
# current_date — Текущая дата в формате UNIX-времени (секунды).
# expiry_days — Количество дней до истечения срока действия токена. Для бессрочных — 9999.
# response — Ответ от API GitLab, содержащий данные токенов или объектов (проекты/группы).
# token_count — Количество токенов на текущей странице ответа API.
# page — Номер текущей страницы для обработки данных при использовании пагинации.
# personal_tokens_url — URL для получения списка активных персональных токенов.
# all_project_ids — Массив ID всех проектов в GitLab для последующей обработки токенов.
# project_tokens_url — URL для получения токенов конкретного проекта.
# project_name — Название проекта, полученное через функцию get_project_name.
# all_groups_ids — Массив ID всех групп в GitLab для обработки групповых токенов.
# groups_tokens_url — URL для получения токенов конкретной группы.
# groups_name — Название группы, полученное через функцию get_group_name.
# start_time — Время начала выполнения скрипта в формате UNIX-времени.
# end_time — Время завершения выполнения скрипта в формате UNIX-времени.
# execution_time — Общее время работы скрипта в секундах.

##--------------------------------------------------- функции -----------------------------------------------------------##
# get_user_login(user_id) — Получает логин пользователя по его ID через API GitLab.
# get_project_name(project_id) — Возвращает название проекта по его ID.
# get_group_name(groups_id) — Возвращает название группы по её ID.
# process_tokens(url, token_type, owner_type, paginate) — Основная функция для обработки токенов:
# - url — API-эндпоинт для запроса токенов.
# - token_type — Тип токена (personal, project, groups).
# - owner_type — Тип владельца (user для персональных, project/groups для других).
# - paginate — Флаг необходимости обработки пагинации (yes/no).

##------------------------------------------------- алгоритм работы -----------------------------------------------------##

# 1. Сбор персональных токенов:
#   - Пагинация через параметры page и per_page.
#   - Определение владельца через user_id.
# 2. Сбор проектных токенов:
#   - Получение списка всех проектов с пагинацией.
#   - Последовательный запрос токенов для каждого проекта.
# 3. Сбор групповых токенов:
#   - Получение списка всех групп с пагинацией.
#   - Обработка токенов для каждой группы.
# 4. Расчет метрик:
#   - Дней до истечения токена (для бессрочных — 9999).
#   - Временная метка последнего использования токена.
# 5. Вывод данных в формате Prometheus с тегами:
#   - name, type, owner, last_used.
# 6. Замер общего времени выполнения скрипта.

# ##-- Особенности обработки:
# - Некорректные токены (без имени или владельца) пропускаются.
# - Для проектов и групп без имени используется значение "unknown_project".
# - Токены с expires_at=null считаются бессрочными (expiry_days=9999).
# - Пагинация обрабатывается для всех типов сущностей (проекты, группы, токены).
# GitLab Token Exporter Bash

![GitLab](https://img.shields.io/badge/GitLab-%23181717.svg?style=flat&logo=gitlab&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=Prometheus&logoColor=white)
![Shell Script](https://img.shields.io/badge/Shell_Script-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)

Скрипт для мониторинга сроков действия токенов GitLab в формате Prometheus.

## 📋 Описание
Скрипт собирает информацию о:
- Персональных токенах доступа
- Проектных токенах
- Групповых токенах
- Времени выполнения скрипта

Результаты экспортируются в формате, пригодном для сбора метрик Prometheus.

## ✨ Особенности
- Поддержка всех типов токенов GitLab
- Автоматическая пагинация запросов
- Определение владельцев токенов (пользователь/проект/группа)
- Расчет:
  - Дней до истечения срока действия
  - Времени с последнего использования
  - Длительности выполнения скрипта
- Фильтрация некорректных записей
- Обработка бессрочных токенов (expiry_days=9999)

## 🚀 Использование

### Требования
- Bash 4.0+
- `curl`
- `jq`
- Доступ к GitLab API (версия 13.0+)

### Запуск
```bash
# Установите переменные окружения
export GITLAB_URL="https://gitlab.example.com"
export API_TOKEN="your-access-token"

# Запуск скрипта
./gitlab_token_exporter.sh

# Пример вывода в Prometheus:
# gitlab_token_expiry_days{name="ci-bot-token", type="project", owner="android-app", last_used="2023-10-25"} 87
# gitlab_token_script_time{name="gitlab_token_script_time", type="script"} 12
# pg-backup-s3

Бэкап PostgreSQL в S3-совместимое хранилище (Yandex Object Storage, Selectel, MinIO) одним Bash-скриптом: `pg_dump` → gzip → проверка архива → загрузка → удаление старых копий → метрики для Prometheus.

## Что умеет

- Ротация по `RETENTION_DAYS` (по дате в имени файла, без зависимости от времени изменения объекта).
- Метрики через textfile collector node_exporter: успех, время запуска, длительность, размер. Файл пишется атомарно.
- Алерты `PgBackupFailed` и `PgBackupTooOld` в `alerts.yml`. Бэкап, про который никто не знает, что он упал, хуже, чем его отсутствие.
- systemd timer с `Persistent=true`: если сервер был выключен ночью, бэкап снимется после включения.
- `restore.sh` для восстановления в новую базу.

## Установка

```bash
sudo install -m 0755 pg-backup-s3.sh /usr/local/bin/
sudo install -D -m 0600 /dev/stdin /etc/pg-backup/app.env <<'ENV'
PGHOST=127.0.0.1
PGUSER=backup
PGDATABASE=app
S3_BUCKET=my-backups
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
ENV
sudo cp systemd/pg-backup@.* /etc/systemd/system/
sudo systemctl enable --now pg-backup@app.timer
```

## Тесты

CI не ограничивается линтером: на каждый коммит поднимаются настоящие PostgreSQL 16 и S3-совместимый сервер (moto), и [`tests/e2e.sh`](tests/e2e.sh) делает полный круг: заполняет базу, снимает бэкап, проверяет удаление просроченной копии и метрики, восстанавливает в новую базу и сверяет количество строк и сумму. Отдельно проверяется, что упавший бэкап пишет `pg_backup_success 0`, а не молчит.

## Проверка восстановления

Раз в месяц: `./restore.sh postgres/app/app-<ts>.sql.gz app_restore_check`, затем сравнить количество строк в ключевых таблицах. Непроверенный бэкап считаем отсутствующим.

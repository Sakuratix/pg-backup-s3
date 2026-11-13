# pg-backup-s3

Бэкап PostgreSQL в S3-совместимое хранилище (Yandex Object Storage, Selectel, MinIO) одним Bash-скриптом: `pg_dump` → gzip → проверка архива → загрузка → удаление старых копий → метрики для Prometheus.

## Что умеет

- Ротация по `RETENTION_DAYS` (по дате в имени файла, без зависимости от времени изменения объекта).
- Метрики через textfile collector node_exporter: успех, время запуска, длительность, размер. Файл пишется атомарно.
- Алерты `PgBackupFailed` и `PgBackupTooOld` в `alerts.yml`. Бэкап, про который никто не знает, что он упал, хуже, чем его отсутствие.
- systemd timer с `Persistent=true`: если сервер был выключен ночью, бэкап снимется после включения.
- `restore.sh` для восстановления в новую базу.
- Шифрование [age](https://age-encryption.org) открытым ключом: `AGE_RECIPIENT=age1...`. Приватного ключа на сервере с базой нет, поэтому утёкший доступ к бакету или к самому серверу не даёт прочитать бэкапы. Восстановление: `AGE_IDENTITY=/path/to/key ./restore.sh ...sql.gz.age newdb`.

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

CI не ограничивается линтером: на каждый коммит поднимаются настоящие PostgreSQL 17 и S3-совместимый сервер (moto), и [`tests/e2e.sh`](tests/e2e.sh) делает полный круг: заполняет базу, снимает бэкап, проверяет удаление просроченной копии и метрики, восстанавливает в новую базу и сверяет количество строк и сумму, а для зашифрованного бэкапа проверяет, что без ключа он не читается и не восстанавливается. Отдельно проверяется, что упавший бэкап пишет `pg_backup_success 0`, а не молчит.

Тест сразу поймал реальную ловушку: `pg_dump` 17 пишет в дамп `SET transaction_timeout`, и восстановление в PostgreSQL 16 падает. Версия `pg_dump` должна совпадать с версией сервера, в который восстанавливаешь, или быть не новее его.

## Проверка восстановления

Непроверенный бэкап считаем отсутствующим, поэтому проверка автоматическая. `restore-check.sh` раз в неделю (systemd timer `pg-restore-check@.timer`):

1. берёт последний бэкап из бакета (зашифрованный тоже, с `AGE_IDENTITY`);
2. восстанавливает его во временную базу;
3. проверяет, что таблицы есть, при желании ещё что в `CHECK_TABLE` не меньше `CHECK_MIN_ROWS` строк и что `CHECK_SQL` возвращает true;
4. удаляет временную базу, даже если что-то упало;
5. пишет метрики: успех, сколько длилось восстановление (это и есть реальный RTO) и сколько часов было бэкапу.

Алерты `PgRestoreCheckFailed` и `PgRestoreCheckTooOld` в `alerts.yml`.

```bash
sudo install -m 0755 restore.sh restore-check.sh /usr/local/bin/
sudo cp systemd/pg-restore-check@.* /etc/systemd/system/
sudo systemctl enable --now pg-restore-check@app.timer
```

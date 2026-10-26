# home-lab — домашний медиасервер на Talos Linux

Конфигурация домашнего медиасервера целиком: от машинного конфига ОС до
последнего Deployment. Один узел, на нём **Talos Linux** как одноузловой
кластер Kubernetes: control plane и вся нагрузка на одной машине. Задача у
него одна — качать и показывать: Sonarr/Lidarr/Prowlarr ищут, Deluge качает,
Jellyfin показывает.

У Talos нет shell, SSH и пакетного менеджера. Всё, что происходит с узлом, —
это `talosctl` через API на порту 50000, а всё, что на нём работает, —
манифесты из этого репозитория. Переустановка с нуля сводится к шагам ниже, и
все инструменты для них собраны в один Docker-образ.

В репозитории нет ни одного секрета: только шаблоны и скрипт, который их
заполняет.

### Железо

| | |
|---|---|
| CPU | x86-64, 8 ядер / 16 потоков (AMD Zen 4) |
| GPU | встроенная AMD Radeon с VAAPI — аппаратное транскодирование в Jellyfin |
| Системный диск | NVMe: Talos, `/var` (200 ГиБ) и всё остальное под PVC |
| Медиа | HDD 18 ТБ по USB, XFS |
| Бэкапы | SSD 4 ТБ по USB, XFS |

Подойдёт любая x86-64-машина. На Intel замените расширения `amd-ucode` и
`amdgpu` в `talos/talconfig.yaml` на `intel-ucode` и `i915`.

### Что внутри

| Слой | Что | Где |
|------|-----|-----|
| ОС | Talos Linux v1.14, образ из Image Factory (microcode, драйвер GPU) | `talos/` |
| Сеть кластера | Cilium с заменой kube-proxy, WireGuard-шифрование между подами | `server/helm/cilium/` |
| Хранилище | local-path-provisioner на томе NVMe; медиа и бэкапы — hostPath на XFS-дисках | `server/local-path/`, `talos/patches/volumes.yaml` |
| Ingress и TLS | Traefik на hostPort 80/443, Let's Encrypt через DNS-01 в Cloudflare | `server/helm/traefik/` |
| Секреты | Bitnami Sealed Secrets: в git лежат только зашифрованные блобы | `server/SECRETS.md` |
| Мониторинг | Prometheus + node-exporter + Grafana, дашборды подтягиваются по id при старте | `server/monitoring/` |
| Бэкап | ночной CronJob: снапшоты всех PVC с hard link-ами на прошлую ночь | `server/apps/backup/` |
| Приложения | Jellyfin, Sonarr, Lidarr, Prowlarr, Bazarr, Deluge, Byparr (замена FlareSolverr), Musicseerr, Suwayomi, Homarr | `server/apps/`, `server/helm/homarr/` |

Доступ:

- **Публичные** имена: `tv.example.com` (Jellyfin) и `manga.example.com`
  (Suwayomi) — Ingress с сертификатом Let's Encrypt.
- **Интранет** `<app>.l.example.com`: Sonarr, Lidarr, Prowlarr, Bazarr,
  Deluge, Musicseerr, Grafana, Prometheus, Homarr (`home.l.example.com`),
  дашборд Traefik. Общий wildcard-сертификат `*.l.example.com` и Middleware
  `lan-only`: пускает только `192.168.0.0/16`, остальным 403. Логин — у
  каждого приложения свой; у Prometheus и дашборда Traefik его нет, их
  защищает только `lan-only`.
- **NodePort** — для небраузерных клиентов: Jellyfin на ТВ и телефоне (30008),
  thin client Deluge (30006), Mihon/Tachiyomi для Suwayomi (30003).

Межсетевой экран узла включён (`talos/patches/firewall.yaml`): по умолчанию
всё закрыто; снаружи открыты 80/443, из LAN — ещё API Talos и Kubernetes и
три NodePort.

### Структура репозитория

```
.
├── Dockerfile               все инструменты для деплоя (talosctl, talhelper, kubectl, helm, helmfile, kubeseal…)
├── Makefile                 шаги этого README одной командой каждый (`make help`)
├── scripts/init-secrets.sh  шаблоны секретов → cleartext-файлы со случайными паролями
├── talos/
│   ├── talconfig.yaml       описание узла для talhelper
│   └── patches/             cluster, node, volumes, firewall
└── server/
    ├── helmfile.yaml        Helm-релизы с версиями…
    ├── helmfile.lock        …и зафиксированный lock
    ├── helm/<chart>/        values для чартов
    ├── kustomization.yaml   корневой Kustomize-оверлей: apps + monitoring
    ├── apps/<app>/          по каталогу на приложение, один объект — один файл
    ├── monitoring/          Prometheus, Grafana, node-exporter
    ├── local-path/          StorageClass по умолчанию
    ├── secrets-unsealed/    шаблоны cleartext-секретов (*.yaml.example); сами секреты в .gitignore
    ├── Makefile             seal / fetch-cert / backup-key / check-cleartext
    ├── validate.sh          офлайн-проверка kubeconform
    ├── README.md            подробности про манифесты, NodePort, Helm (англ.)
    └── SECRETS.md           как устроены Sealed Secrets, бэкап ключа (англ.)
```

## Что поменять под себя

Всё, что зависит от вашей сети и железа, — заглушки или примеры:

| Что | Значение здесь | Где встречается |
|-----|----------------|-----------------|
| Домен | `example.com` (+ `l.example.com` для интранета) | Ingress-ы, `helm/traefik/values.yml`, `GF_SERVER_ROOT_URL` у Grafana |
| IP узла | `192.168.1.2`, шлюз `192.168.1.1`, LAN `192.168.1.0/24` | `talos/`, `Makefile` (`NODE`) |
| Сетевая карта | MAC `00:00:00:00:00:00` | `talos/talconfig.yaml` (`deviceSelector`) |
| Системный диск | серийник `YOUR_NVME_SERIAL` | `talos/talconfig.yaml` (`installDiskSelector`) |
| Имя узла, кластера и kube-контекста | `home-lab` | `talos/talconfig.yaml`, `nodeAffinity` в манифестах, `kubeContext` в `helmfile.yaml` |
| Почта для Let's Encrypt | `admin@example.com` | `helm/traefik/values.yml` |
| Часовой пояс | `Etc/UTC` | `TZ` в манифестах, `timeZone` у CronJob бэкапа |
| Пользователь Suwayomi | `user` | `server/secrets-unsealed/suwayomi.yaml.example` |

MAC и серийник проще всего узнать у самого узла, когда он загрузится с
флешки (шаг 2). Домен и сеть заменяются разом (GNU sed есть в Docker-образе):

```sh
grep -rlE 'example\.com|192\.168\.1\.' talos server Makefile \
  | xargs sed -i -e 's/example\.com/your.domain/g' \
                 -e 's/192\.168\.1\.2\b/10.0.0.5/g' \
                 -e 's/192\.168\.1\.1\b/10.0.0.1/g' \
                 -e 's/192\.168\.1\.0/10.0.0.0/g'
```

Если LAN у вас не внутри `192.168.0.0/16`, поправьте ещё allow-list в
`server/apps/intranet/intranet-lan-only-middleware.yaml` и подсети LAN в
`talos/patches/firewall.yaml`.

## Инструменты: Docker-образ

Для деплоя нужен набор CLI строго определённых версий: `talosctl` под версию
узла, `kubectl` под версию Kubernetes, `kubeseal` не новее контроллера. Всё это
собрано в `Dockerfile` (Debian trixie, бинарники с GitHub-релизов, версии — в
`ARG`-ах в начале файла):

```sh
make shell          # docker build + docker run с нужными монтированиями
```

Внутри контейнера репозиторий смонтирован в `/work` (рабочий каталог,
`TALOSCONFIG=/work/talos/clusterconfig/talosconfig`), а `~/.kube` хоста — в
`/root/.kube`, так что kubeconfig переживает контейнер. Все команды ниже
выполняются внутри `make shell`, из `/work`.

Узел по умолчанию `192.168.1.2`; другой передаётся как `make shell
NODE=10.0.0.5` или `make <target> NODE=…`.

> На macOS держите клон в домашнем каталоге: Docker Desktop монтирует только
> каталоги из своего списка File Sharing, а остальные молча видны в
> контейнере пустыми.

## Развёртывание с нуля

Порядок важен: до шага 3 в кластере нет CNI и не стартует ни один под; до
шага 6 нет контроллера Sealed Secrets и CRD Traefik. `make cluster-up` (шаг 6)
повторяет шаги 3 и 6 одной командой, но на совсем пустом узле удобнее пройти их
по одному.

### Шаг 0. Сеть и DNS

**Роутер:**

- DHCP-резерв `192.168.1.2` за MAC узла: установщик Talos в maintenance mode
  получает адрес по DHCP, и он должен совпасть со статическим из
  `talconfig.yaml`.
- Проброс TCP 80 и 443 с публичного IP на узел, плюс NAT loopback, чтобы
  публичные имена открывались и из дома.
- Имена `*.l.example.com` должны резолвиться в `192.168.1.2` **напрямую**:
  через публичный IP запрос приходит с чужим адресом источника, и `lan-only`
  ответит 403. Проще всего — статическая DNS-запись (wildcard) на роутере.
  Если роутер так не умеет, можно завести публичную запись
  `*.l.example.com A 192.168.1.2`, но часть роутеров режет такие ответы
  (защита от DNS rebinding) — тогда разрешите это для своего домена.

**Cloudflare.** Зона домена на Cloudflare, A-записи `tv` и `manga` указывают
на домашний IP. Для интранета записи не нужны: сертификаты выпускаются через
DNS-01. Создайте API-токен с правом **Zone → DNS → Edit** на эту зону — он
понадобится на шаге 5. Другой DNS-провайдер — поменяйте `dnsChallenge.provider`
и переменную окружения в `server/helm/traefik/values.yml` (список провайдеров —
в документации Traefik/lego).

### Шаг 1. Секреты Talos

talhelper хранит PKI кластера в `talos/talsecret.yaml`. Файл в `.gitignore`, но
он важен: без него узел можно только переустановить, а не перенастроить.
Сохраните копию в менеджер паролей.

```sh
make shell
talhelper gensecret > talos/talsecret.yaml
make talos-gen                       # → talos/clusterconfig/ (в .gitignore: там PKI открытым текстом)
```

### Шаг 2. Установка Talos

```sh
make talos-image-url
```

Первая строка — ISO для флешки, вторая — installer для будущих обновлений. ID
схематика в URL — хеш набора расширений и аргументов ядра из `talconfig.yaml`,
так что Image Factory соберёт ровно этот образ.

Запишите ISO на флешку и загрузите с неё узел (Secure Boot в прошивке
выключен). Talos поднимется в maintenance mode и получит адрес по DHCP. Узнайте
серийник системного диска и MAC сетевой карты:

```sh
talosctl -n 192.168.1.2 get disks --insecure
talosctl -n 192.168.1.2 get links --insecure       # колонка HW ADDR
```

Впишите их в `installDiskSelector.serial` и `deviceSelector.hardwareAddr` в
`talos/talconfig.yaml`, затем `make talos-gen` и проверка:

```sh
make talos-gen
talosctl validate --mode metal --config talos/clusterconfig/home-lab-home-lab.yaml
```

Дальше — точка невозврата: **системный NVMe будет стёрт**.

```sh
make talos-install                   # apply-config --insecure: ставит на NVMe и перезагружает
# пока узел перезагружается, выньте флешку
make talos-bootstrap                 # инициализация etcd — ровно один раз за жизнь кластера
make talos-kubeconfig                # kubeconfig в ~/.kube/config, контекст `home-lab`
talosctl -n 192.168.1.2 get volumestatus
```

Имя контекста важно: `server/helmfile.yaml` привязан к `kubeContext:
home-lab`, чтобы `helmfile apply` случайно не уехал в чужой кластер.

`kubectl get nodes` покажет узел в `NotReady` — так и должно быть, CNI ещё нет.
В `volumestatus` том `u-local-path` должен быть `ready`, а `e-media` и
`e-backup` будут ждать дисков с нужными метками разделов (шаг 4).

### Шаг 3. Cilium

Talos поставлен без CNI и без kube-proxy (`cniConfig: none` и патч
`talos/patches/cluster.yaml`), их обоих заменяет Cilium:

```sh
cd server && helmfile -l name=cilium sync && cd ..
kubectl wait --for=condition=Ready node --all --timeout=10m
```

На пустом кластере везде `sync`, а не `apply`: `apply` сначала зовёт
`helm diff`, а тот падает на объектах, чьих CRD ещё нет.

### Шаг 4. Диски под медиа и бэкапы

NVMe Talos размечает сам: системные разделы, `EPHEMERAL` (`/var`) с потолком
200 ГиБ и всё остальное — XFS-том `local-path` под PVC
(`talos/patches/volumes.yaml`). Два внешних диска описаны как
`ExistingVolumeConfig`: Talos монтирует их, но не форматирует. Ищет он разделы
по **GPT-метке**, а не по `sdX` (USB-корпуса перетасовывают имена устройств
при каждом сбросе):

| Метка раздела | Монтируется в | Что там |
|---------------|---------------|---------|
| `media-xfs` | `/var/mnt/media` | медиатека и загрузки (`downloads/`) |
| `backup` | `/var/mnt/backup` | ночные снапшоты PVC (`apps/backup`) |

SSH на узле нет, поэтому разметка — из одноразового привилегированного пода
(`--profile=sysadmin` видит устройства хоста, корень хоста смонтирован в `/host`):

```sh
kubectl debug node/home-lab -it --profile=sysadmin --image=alpine:3.22.2 -- sh
apk add --no-cache parted xfsprogs lsblk
lsblk -o NAME,SIZE,SERIAL,FSTYPE,PARTLABEL       # найдите оба диска по размеру
# ВНИМАНИЕ: стирает диски. sdX — под медиа, sdY — под бэкапы, подставьте свои.
parted -s /dev/sdX mklabel gpt mkpart media-xfs xfs 0% 100% && mkfs.xfs -f -L media-xfs /dev/sdX1
parted -s /dev/sdY mklabel gpt mkpart backup    xfs 0% 100% && mkfs.xfs -f -L backup    /dev/sdY1
exit
```

Через несколько секунд `talosctl -n 192.168.1.2 get volumestatus` покажет
`e-media` и `e-backup` как `ready` (если нет — `talosctl -n 192.168.1.2
reboot`). Уже **новым** debug-подом (старый не видит того, что смонтировано
после его старта) создайте каталоги, которые манифесты подключают как
`hostPath` с `type: Directory` — без них поды не стартуют — и маркер тома
бэкапов: без него CronJob откажется писать, чтобы не забить NVMe, если диск
не смонтировался. Владелец медиа — uid/gid 1001, под ним работают контейнеры
linuxserver.io (`PUID`/`PGID`):

```sh
kubectl debug node/home-lab -it --profile=sysadmin --image=alpine:3.22.2 -- sh
mkdir -p /host/var/mnt/media/downloads/Music
chown -R 1001:1001 /host/var/mnt/media
touch /host/var/mnt/backup/.backup-volume
exit
kubectl get pods -o name | grep node-debugger | xargs kubectl delete
```

### Шаг 5. Секреты Kubernetes

Каждому `Secret` в кластере соответствуют три файла:

```
server/secrets-unsealed/<slug>.yaml.example   шаблон, в git
server/secrets-unsealed/<slug>.yaml           открытый текст, в .gitignore — вход kubeseal
server/<dir>/<slug>-sealedsecret.yaml         зашифрованный результат — его коммитят и применяют
```

Шаблоны превращаются в настоящие файлы одной командой:

```sh
make secrets-init
```

Скрипт (`scripts/init-secrets.sh`) копирует каждый шаблон, заменяет
плейсхолдеры `@GEN…@` случайными значениями и запоминает их в
`secrets-unsealed/.generated.json`. Существующие файлы он не трогает, так что
его можно запускать повторно. В конце — список файлов, где остались `CHANGE_ME`.

| Файл | Что | Когда |
|------|-----|-------|
| `cloudflare.yaml` | API-токен Cloudflare (шаг 0) | **сейчас**, без него нет сертификатов |
| `sonarr.yaml`, `lidarr.yaml`, `prowlarr.yaml` | API-ключ приложения | после первого запуска (шаг 8) |
| `grafana-admin.yaml`, `suwayomi.yaml`, `db-encryption.yaml` | заполнены скриптом | — |

Запечатать стоит всё сразу, вместе с `CHANGE_ME`: Kustomize требует, чтобы
каждый файл из `resources:` существовал, а API-ключи потом перезапечатываются.
Шифруются секреты публичным ключом контроллера Sealed Secrets, которого пока
нет, — поэтому само шифрование происходит на шаге 6. Пароли из
`grafana-admin.yaml` и `suwayomi.yaml` перенесите в менеджер паролей.

### Шаг 6. Всё остальное

```sh
make cluster-up
```

Что внутри, по порядку (см. `Makefile`):

1. `helmfile -l name=cilium sync` и ожидание `Ready` — повтор шага 3, безвреден.
2. `kubectl apply -k server/local-path` — local-path-provisioner и StorageClass
   по умолчанию; без него ни один PVC не привяжется.
3. `helmfile -l name=sealed-secrets sync` — контроллер и CRD `SealedSecret`.
4. `make -C server seal` — все секреты шифруются ключом этого контроллера и
   ложатся рядом с приложениями как `*-sealedsecret.yaml`.
5. `kubectl apply -f server/helm/traefik/cloudflare-sealedsecret.yaml` — он
   единственный в `kube-system` и потому не входит в оверлей (тот
   принудительно ставит `namespace: default`).
6. `helmfile -l name=traefik sync` — Traefik и его CRD (`Middleware`,
   `IngressRoute`), которые нужны оверлею.
7. `kubectl apply -k server` — весь оверлей `apps` + `monitoring`.
8. `helmfile -l name=homarr sync` — homarr, ему нужен секрет `db-encryption`
   из оверлея.

Версии чартов зафиксированы дважды: в `server/helmfile.yaml` и в
`server/helmfile.lock` (`make helm-deps` пересобирает lock после правки версий).

Дождитесь, пока поды поднимутся и все PVC станут `Bound` (local-path привязывает
claim только когда под запланирован):

```sh
kubectl get pods -A
kubectl get pvc -A
```

До шага 8 ожидаемо не поднимутся только exportarr-сайдкары у
Sonarr/Lidarr/Prowlarr: в их секретах ещё `CHANGE_ME`.

Запечатанные файлы закоммитьте в своём форке: без приватного ключа контроллера
они бесполезны и в git безопасны. Проверка, что открытый текст не утёк:

```sh
make -C server check-cleartext
```

### Шаг 7. Ключ sealed-secrets в бэкап

**Сделайте это сразу.** Приватный ключ контроллера существует только в etcd
узла. Переустановили Talos без бэкапа ключа — каждый `*-sealedsecret.yaml` в
репозитории превратился в мусор, и всё придётся перезапечатывать из
`secrets-unsealed/`, которого нет ни в git, ни в бэкапах.

```sh
make -C server backup-key            # → server/secrets-unsealed/sealing-key-backup.yaml
grep -c tls.key server/secrets-unsealed/sealing-key-backup.yaml     # ≥ 1
```

Положите файл в менеджер паролей (рядом с `talsecret.yaml`) и удалите локальную
копию: `shred -u server/secrets-unsealed/sealing-key-backup.yaml`. Контроллер
выпускает новый ключ раз в 30 дней (`keyrenewperiod: 720h`), старые сохраняет —
повторяйте бэкап после каждого обновления.

При переустановке узла ключ восстанавливается **до** установки контроллера, и
тогда старые запечатанные файлы снова расшифровываются:

```sh
sed -E '/^    (resourceVersion|uid|creationTimestamp):/d' sealing-key-backup.yaml | kubectl apply -f -
cd server && helmfile -l name=sealed-secrets sync && cd ..
kubectl -n kube-system logs deploy/sealed-secrets-controller | grep 'registered private key'
```

В этом случае вместо `make cluster-up` выполните его шаги вручную, пропустив
`make -C server seal`: перезапечатывать нечего.

### Шаг 8. Связать приложения

Здесь то, что нельзя описать декларативно. Общий цикл для любого секрета:

```sh
$EDITOR server/secrets-unsealed/<slug>.yaml      # вписать значение
make -C server seal-<slug>                       # перезапечатать один файл
kubectl apply -k server/<dir>                    # cloudflare: kubectl apply -f
kubectl rollout restart deploy/<app>             # env из Secret читается только при старте
```

Внутри кластера приложения видят друг друга по именам сервисов:

| Сервис | Адрес в кластере | Снаружи |
|--------|------------------|---------|
| Sonarr | `http://sonarr:8989` | `https://sonarr.l.example.com` |
| Lidarr | `http://lidarr:8686` | `https://lidarr.l.example.com` |
| Prowlarr | `http://prowlarr:9696` | `https://prowlarr.l.example.com` |
| Bazarr | `http://bazarr:6767` | `https://bazarr.l.example.com` |
| Deluge | `deluge:58846` (daemon), `http://deluge:8112` (web) | `https://deluge.l.example.com` |
| Byparr | `http://flaresolverr:8191` | — |
| Musicseerr | `http://musicseerr:8688` | `https://musicseerr.l.example.com` |
| Jellyfin | `http://jellyfin:8096` | `https://tv.example.com` |

1. **Deluge** — веб-пароль по умолчанию `deluge`, смените его сразу.
2. **Sonarr, Lidarr, Prowlarr** — при первом входе задайте логин
   (Authentication: Forms). Ключ API — **Settings → General → Security → API
   Key**; впишите его в `secrets-unsealed/<app>.yaml` и прогоните цикл выше —
   exportarr-сайдкар начнёт отдавать метрики в Prometheus.
3. В Sonarr и Lidarr: **Settings → Download Clients → Deluge**, хост `deluge`,
   порт 8112. Пути совпадают во всех контейнерах: загрузки — `/downloads`
   (это `/var/mnt/media/downloads`), библиотека Lidarr — `/music`.
4. В Prowlarr: **Settings → Apps** — Sonarr и Lidarr по адресам из таблицы;
   **Indexers → Indexer Proxies → FlareSolverr** — `http://flaresolverr:8191`
   для трекеров за Cloudflare.
5. **Bazarr** — подключите к Sonarr, добавьте провайдеры субтитров.
6. **Jellyfin** — мастер первого запуска на `https://tv.example.com`;
   библиотеки лежат в `/media` (это `/var/mnt/media/downloads`).
   Аппаратное транскодирование: **Dashboard → Playback → VAAPI**, устройство
   `/dev/dri/renderD128`.
7. **Musicseerr** — подключите к Lidarr и Jellyfin.
8. **Grafana** (`https://grafana.l.example.com`) — `admin` и пароль из
   `secrets-unsealed/grafana-admin.yaml`.
9. **Homarr** (`https://home.l.example.com`) — мастер первого запуска, дальше
   доска со ссылками на всё остальное.

### Шаг 9. Проверка

- `kubectl get nodes` — `Ready`; `kubectl get pods -A` — всё `Running`.
- `kubectl get sealedsecret -A` — у всех `SYNCED True`.
- Интранет-имена открываются из LAN, а через публичный IP отвечают 403.
- Публичные имена открываются с валидным сертификатом
  (`kubectl -n kube-system logs deploy/traefik | grep -i acme` — если нет).
- Jellyfin видит GPU: `kubectl exec deploy/jellyfin -- ls /dev/dri`.
- Снаружи отвечают только TCP 80 и 443.
- Через сутки в `/var/mnt/backup/metadata` появился снапшот
  (`kubectl get jobs` — `backup-*` в `Complete`; разово:
  `kubectl create job --from=cronjob/backup backup-manual`).

## Повседневные операции

| Задача | Команда |
|--------|---------|
| Изменить машинный конфиг | правка `talos/`, `make talos-apply` |
| Изменить файрвол | сначала `cd talos && talhelper gencommand apply --extra-flags=--mode=try \| sh` — откатится сам, если не подтвердить |
| Обновить Talos / расширения / аргументы ядра | `talosVersion` в `talconfig.yaml` (и `TALOSCTL_VERSION` в `Dockerfile`), `make talos-upgrade` — с перезагрузкой |
| Обновить Kubernetes | `kubernetesVersion` (и `KUBECTL_VERSION`, `K8S_VERSION` в `server/validate.sh`), `make talos-upgrade-k8s` |
| Логи и сервисы узла | `talosctl -n 192.168.1.2 logs kubelet`, `talosctl services`, `talosctl dmesg` |
| Shell на узле | `kubectl debug node/home-lab -it --profile=sysadmin --image=alpine:3.22.2` |
| Что изменится в кластере | `kubectl diff -k server` |
| Применить одно приложение | `kubectl apply -k server/apps/<app>` |
| Обновить чарт | версия в `server/helmfile.yaml`, `make helm-deps`, `cd server && helmfile -l name=<release> apply` |
| Проверить манифесты без кластера | `make server-validate`, `make server-helm` |
| Восстановить PVC из бэкапа | см. комментарий в `server/apps/backup/kustomization.yaml` |

Новую версию Talos сначала «прогрейте»: Image Factory собирает схематик по
первому запросу дольше минуты, а `talosctl upgrade` столько не ждёт.
`make talos-image-url` печатает installer; дёргайте
`curl -sI https://factory.talos.dev/v2/metal-installer/<id>/manifests/<tag>`
до ответа 200, потом обновляйтесь.

**Новое веб-приложение в интранет:** скопируйте любой `*-ingress.yaml` с
`.l.example.com`, впишите его в `kustomization.yaml` каталога — DNS и
wildcard-сертификат уже покрывают новое имя. Новый NodePort или
hostNetwork-порт — это две правки: манифест **и** порт в
`talos/patches/firewall.yaml`.

**Новый секрет:** шаблон `secrets-unsealed/<slug>.yaml.example`, строка
`<slug>:<dir>` в `SECRETS` в `server/Makefile`, `<slug>-sealedsecret.yaml` в
`resources:` каталога приложения. Подробно — `server/SECRETS.md`.

**Убрать приложение:** строку из `server/apps/kustomization.yaml`, его секрет из
`SECRETS` в `server/Makefile` и шаблон, NodePort — из файрвола.

## Версии

Всё зафиксировано явно — ни одного `:latest`. Образы приложений — тегами или
дайджестами прямо в манифестах (`grep -rn 'image:' server`), чарты — в
`server/helmfile.yaml` и `server/helmfile.lock`.

| Компонент | Версия | Где закреплено |
|-----------|--------|----------------|
| Talos | v1.14.2 | `talos/talconfig.yaml` |
| Kubernetes | v1.36.3 | `talos/talconfig.yaml` |
| Cilium | 1.20.2 | `server/helmfile.yaml` (не ниже: ядру 7.2 нужен фикс из 1.20.2) |
| Traefik (чарт) | 41.7.1 | `server/helmfile.yaml` |
| Sealed Secrets (чарт / контроллер) | 2.20.0 / 0.40.0 | `server/helmfile.yaml` |
| homarr (чарт) | 8.34.1 | `server/helmfile.yaml` |
| local-path-provisioner | v0.0.36 | `server/local-path/kustomization.yaml` |

Инструменты в `Dockerfile`: talosctl 1.14.2, talhelper 3.1.17, kubectl
1.36.3, helm 4.3.1 + helm-diff 3.15.14, helmfile 1.8.0, kubeseal 0.40.0,
kubeconform 0.8.0, yq 4.54.1. Поднимая версию узла или контроллера, поднимите
и соответствующий `ARG`.

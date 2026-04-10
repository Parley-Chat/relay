# Parley Chat Relay

یک پروکسی معکوس سبک برای [Parley Chat](https://github.com/Parley-Chat) که جلوی بک‌اند Sova قرار می‌گیرد. با این ابزار می‌توانید مسیرهای در معرض دید را کنترل کنید، مسیرهای ناخواسته را مسدود کنید، درخواست‌های فرانت‌اند را هدایت کنید و ترافیک را از طریق یک پروکسی HTTP یا SOCKS5 بالادست عبور دهید.

## چیست

Relay یک برنامهٔ Python است (Flask + Waitress) که درخواست‌های HTTP را دریافت کرده و به یک بک‌اند Sova پیکربندی‌شده ارسال می‌کند. این ابزار به عنوان نقطهٔ ورودی عمومی یک نصب Parley Chat طراحی شده است.

قابلیت‌های اصلی:

- **مسیرهای مدیریت‌شده** — هر پیشوند مسیر می‌تواند به‌صورت مستقل به بک‌اند پروکسی شود، مسدود گردد (403) یا به آدرس دیگری هدایت شود
- **فیلتر متد HTTP** — قوانین می‌توانند فقط برای متدهای خاص (GET، POST، PATCH و ...) اعمال شوند تا کنترل دقیق در سطح API فراهم شود
- **مدیریت فرانت‌اند** — فرانت‌اند Mura را از یک دایرکتوری محلی ارائه دهید، به یک URL جداگانه هدایت کنید یا مسیرهای غیر API را کاملاً غیرفعال کنید
- **پروکسی بالادست** — تمام درخواست‌های خروجی به بک‌اند را از طریق یک پروکسی HTTP یا SOCKS5 عبور دهید
- **استریم SSE** — مسیر `/api/v1/stream` با پشتیبانی کامل از Server-Sent Events پروکسی می‌شود
- **nginx و SSL** — نصب‌کننده nginx خودش را با گواهی‌نامهٔ Let's Encrypt یا خودامضا راه‌اندازی می‌کند

## نصب

دانلود و اجرای نصب‌کننده:

```bash
wget -qO install.sh https://github.com/Parley-Chat/relay/releases/latest/download/install.sh && sudo bash install.sh
```

یا با curl:

```bash
curl -fsSL https://github.com/Parley-Chat/relay/releases/latest/download/install.sh | sudo bash
```

اسکریپت مراحل زیر را طی می‌کند:

1. دامنه یا آدرس IP
2. پیشوند مسیر URI (باید با مقدار `uri_prefix` در `config.toml` Sova مطابقت داشته باشد)
3. آدرس بک‌اند Sova (مثلاً `http://127.0.0.1:42836`)
4. دایرکتوری نصب
5. تعداد thread
6. پروکسی معکوس nginx (اختیاری) با انتخاب گواهی SSL
7. پروکسی بالادست (اختیاری)
8. حالت فرانت‌اند

اسکریپت وابستگی‌های Python را نصب می‌کند، `config.toml` را می‌نویسد، سرویس‌های systemd (`parley-relay` و اختیاری `parley-relay-nginx`) را ایجاد کرده و همه چیز را راه‌اندازی می‌کند.

برای حذف نصب:

```bash
sudo bash install.sh
# گزینه [X] Uninstall را انتخاب کنید
```

## مرجع پیکربندی

Relay فایل `config.toml` را از دایرکتوری کاری خود می‌خواند. تمام فیلدها:

```toml
version = 1

# باید با uri_prefix Sova مطابقت داشته باشد. اگر Sova پیشوندی ندارد، خالی بگذارید.
uri_prefix = "your20charprefix"

[server]
    host = "127.0.0.1"   # آدرس bind
    port = 7861           # پورت bind
    threads = 16          # تعداد thread های Waitress
    max_content_length = 67108864  # حداکثر اندازهٔ بدنهٔ درخواست (64 مگابایت)

[backend]
    url = "http://127.0.0.1:42836"  # آدرس بک‌اند Sova

[upstream_proxy]
    enabled = false
    url = ""  # مثلاً "socks5://user:pass@host:1080" یا "http://proxy:3128"

[frontend]
    # "serve"    — فایل‌های استاتیک را از `directory` ارائه می‌دهد
    # "forward"  — تمام درخواست‌های غیر API را به `url` هدایت می‌کند
    # "disabled" — برای تمام مسیرهای غیر API خطای 404 برمی‌گرداند
    mode = "serve"
    directory = "/opt/parley-relay/mura"
    url = ""  # هنگامی استفاده می‌شود که mode = "forward" باشد

# مسیرهای مدیریت‌شده — به ترتیب بررسی می‌شوند، اولین تطابق prefix+method برنده است.
# action: "proxy"، "block" یا "redirect"
# methods: لیست اختیاری متدهای HTTP — در صورت حذف، با همه متدها تطابق دارد
# block_files: بولین اختیاری (فقط action="proxy") — درخواست‌های multipart حاوی فایل را
#              با 403 رد می‌کند، اما form postهای بدون فایل را عبور می‌دهد
# برای "redirect": target = "https://example.com"
#                  code = 301 (پیش‌فرض)، 302، 307، یا 308

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/pfp"
    action = "proxy"

[[paths]]
    prefix = "/attachment"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

## مسیرهای مدیریت‌شده

مسیرهای مدیریت‌شده به شما امکان می‌دهند کنترل کنید که relay با هر مسیر ورودی قبل از رسیدن به هندلر فرانت‌اند چه کاری انجام دهد.

هر ورودی دارای یک `prefix` و یک `action` است. فیلد اختیاری `methods` امکان اعمال قانون فقط برای متدهای HTTP خاص را فراهم می‌کند:

| Action | رفتار |
|--------|-------|
| `proxy` | درخواست را به بک‌اند Sova هدایت کرده و پاسخ را برمی‌گرداند |
| `block` | خطای 403 Forbidden با بدنهٔ JSON برمی‌گرداند |
| `redirect` | بر اساس کد مشخص‌شده در `code` (پیش‌فرض 301) به `target` هدایت می‌کند |

قوانین **به ترتیب** بررسی می‌شوند — اولین قانونی که هم prefix و هم متد (در صورت تعریف) با آن تطابق داشته باشد، اعمال می‌شود.

### تطابق با wildcard

از `*` می‌توان در هر جایی از prefix استفاده کرد تا با هر رشته‌ای درون یک بخش از مسیر (segment) تطابق داشته باشد:

| الگو | تطابق دارد | تطابق ندارد |
|------|------------|-------------|
| `/api/v1/channel/*/messages` | `/api/v1/channel/abc123/messages` | `/api/v1/channel/messages` |
| `/api/v1/channel/a*a/messages` | `/api/v1/channel/abca/messages` | `/api/v1/channel/abc/messages` |

Wildcardها فقط درون segment خود گسترش می‌یابند و از `/` عبور نمی‌کنند. الگوی wildcard همچنان به عنوان prefix عمل می‌کند — اگر مسیر از الگو فراتر رود، باز هم تطابق دارد.

```toml
# مسدود کردن ارسال پیام فقط در کانال‌های خاص
[[paths]]
    prefix = "/api/v1/channel/announcements-*/messages"
    methods = ["POST"]
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

مسیرهای پیش‌فرض مدیریت‌شده مطابق با مسیرهای واقعی Sova هستند:

| پیشوند | هدف |
|--------|-----|
| `/api/v1` | تمام نقاط پایانی REST API (احراز هویت، کانال‌ها، پیام‌ها، اعضا، کلیدها، پین‌ها، تماس‌ها) |
| `/pfp` | ارائهٔ فایل‌های تصویر پروفایل |
| `/attachment` | ارائهٔ فایل‌های پیوست پیام |
| `/health` | بررسی سلامت سرویس |

## کنترل دقیق API

فیلد `methods` امکان اعمال قوانین متفاوت برای متدهای مختلف روی یک مسیر را می‌دهد.

### اجازهٔ خواندن، مسدود کردن نوشتن

```toml
[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST", "PATCH", "DELETE"]
    action = "block"

[[paths]]
    prefix = "/api/v1/channel"
    # بدون methods — با همه متدهای باقی‌مانده (GET، OPTIONS، ...) تطابق دارد
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

### نمونهٔ فقط خواندنی (read-only)

مسدود کردن تمام عملیات نوشتن در کل API:

```toml
[[paths]]
    prefix = "/api/v1"
    methods = ["POST", "PUT", "PATCH", "DELETE"]
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/pfp"
    action = "proxy"

[[paths]]
    prefix = "/attachment"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

### مسدود کردن ثبت‌نام و ورود

```toml
[[paths]]
    prefix = "/api/v1/signup"
    action = "block"

[[paths]]
    prefix = "/api/v1/login"
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

## کنترل دسترسی به فایل

### مسدود کردن دانلود پیوست‌ها

```toml
[[paths]]
    prefix = "/attachment"
    action = "block"
```

### مسدود کردن تصاویر پروفایل

```toml
[[paths]]
    prefix = "/pfp"
    action = "block"
```

### مسدود کردن آپلود فایل

در Sova، آپلود فایل مسیر جداگانه‌ای ندارد — فایل‌ها به عنوان multipart form data در درون فراخوانی‌های API عادی ارسال می‌شوند:

- **پیوست پیام‌ها** از طریق `POST /api/v1/channel/<id>/messages` آپلود می‌شوند (همان endpoint ارسال پیام متنی)
- **تصویر پروفایل** از طریق `PATCH /api/v1/me` آپلود می‌شود (همان endpoint تغییر نام نمایشی)

از `block_files = true` استفاده کنید تا relay محتوای multipart را بررسی کند: اگر درخواست حاوی بخش‌های فایل باشد با 403 رد می‌شود؛ اگر form post ساده باشد (پیام متنی، تغییر نام) به بک‌اند ارسال می‌شود.

**مسدود کردن آپلود پیوست با حفظ قابلیت ارسال پیام متنی:**

```toml
[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/channel"
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

**مسدود کردن آپلود تصویر پروفایل با حفظ قابلیت تغییر نام:**

```toml
[[paths]]
    prefix = "/api/v1/me"
    methods = ["PATCH"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/me"
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

**مسدود کردن همه آپلودها و دانلودها:**

```toml
[[paths]]
    prefix = "/attachment"
    action = "block"

[[paths]]
    prefix = "/pfp"
    action = "block"

[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/me"
    methods = ["PATCH"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

### کدهای redirect

| کد | معنی |
|----|------|
| `301` | دائمی — مرورگر کش می‌کند؛ ممکن است متد به GET تغییر کند |
| `302` | موقت — کش نمی‌شود؛ ممکن است متد به GET تغییر کند |
| `307` | موقت — کش نمی‌شود؛ **متد اصلی حفظ می‌شود** |
| `308` | دائمی — کش می‌شود؛ **متد اصلی حفظ می‌شود** |

```toml
[[paths]]
    prefix = "/old-api"
    action = "redirect"
    target = "https://example.com/new-api"
    # code = 301   ← پیش‌فرض

[[paths]]
    prefix = "/beta"
    action = "redirect"
    target = "https://example.com/beta-new"
    code = 307
```

## راه‌اندازی دستی

```bash
pip3 install -r requirements.txt
python3 main.py
```

فایل `config.toml` باید در همان دایرکتوری `main.py` وجود داشته باشد.

## مجوز

MIT

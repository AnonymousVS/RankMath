# RankMath

Bulk Connect Account สำหรับ **Rank Math SEO** plugin บน WordPress ทุกเว็บใน cPanel/WHM อัตโนมัติ พร้อม Parallel + Telegram notification

---

## ✨ การทำงาน

Script อ่าน config (Rank Math credentials) → สแกน WordPress ทุกเว็บผ่าน `/etc/trueuserdomains` → ตรวจสภาพ Rank Math plugin บนแต่ละเว็บ → inject account ใหม่ → verify → แจ้งผล

### 4 สถานะที่เป็นไปได้ต่อเว็บ

| Status | เกิดเมื่อ | ผลลัพธ์ |
|---|---|---|
| ✔️ **ALREADY** | account ใหม่ติดตั้งแล้ว | ข้าม (ไม่ทำอะไร) |
| 🔄 **OVERWRITE** | มี account อื่นอยู่ | เปลี่ยนเป็นใหม่ + แจ้ง Rank Math service ปลด account เก่า |
| ✅ **PASS** | ไม่มี account | inject ใหม่ |
| ⏭ **NOPLUGIN** | ไม่มี Rank Math plugin / inactive | ข้าม |

### ขั้นตอนการ inject (ต่อเว็บ)

```
1. ตรวจ Plugin       → Rank Math active ไหม?
2. ตรวจ account      → ปัจจุบัน username เป็นอะไร?
3. Inject            → เขียน registration_data ใหม่ผ่าน Rank Math API
4. Flush cache       → wp_cache + LiteSpeed Purge
5. Verify            → อ่านกลับมา เช็ค api_key ตรงไหม?
6. Deactivate (BG)   → ถ้า OVERWRITE → curl ไป rankmath.com ปลด account เก่า
```

---

## 🛡 ข้อกำหนด

- AlmaLinux 9 / cPanel/WHM
- WP-CLI ติดตั้งแล้ว
- Rank Math SEO plugin ติดตั้ง + active บนเว็บที่ต้องการ
- `flock`, `curl`, `getent`
- `/etc/trueuserdomains` พร้อมใช้งาน

---

## 🚀 วิธีใช้งาน

📄 **คำสั่งรัน + ขั้นตอนทั้งหมด → [Google Doc](https://docs.google.com/document/d/1lnoznw6WxO-1hFEM6yyGTi688ksqN2UA3P2kwHej6gw/edit?usp=sharing)**

> ⚠️ ต้องมี GitHub Personal Access Token ก่อนรัน (อ่าน config repo ที่เป็น private)

---

## 🎛 Mode การทำงาน

| Mode | ใช้เมื่อ |
|---|---|
| **1. ทั้งเซิร์ฟเวอร์** | Connect ทุกเว็บใน cPanel ทั้งเซิร์ฟเวอร์ |
| **2. เลือกบาง cPanel** | เลือกเฉพาะ cPanel ที่ต้องการ (พิมพ์หมายเลข `1 3 5` หรือ `1,3,5`) |

พิมพ์ `q` / `quit` / `exit` เพื่อออกได้ตลอด

---

## 📊 Output ตัวอย่าง

```
✔️  ALREADY: [1/250] user01/example.com | user=ufavision
🔄 OVERWRITE: [2/250] user01/shop.com | oldacct → ufavision
✅ PASS: [3/250] user02/blog.com | https://blog.com
⏭  SKIP: [4/250] user02/test.com
```

### Summary Banner

```
╔══════════════════════════════════════════════╗
║  SUMMARY                                      ║
╠══════════════════════════════════════════════╣
║  Total WordPress    : 250                    ║
║  Pass               : 245  (overwrite 200)   ║
║  Already            : 3                      ║
║  Fail               : 1                      ║
║  No Plugin          : 1                      ║
╚══════════════════════════════════════════════╝
```

---

## 📱 Telegram Notification

ส่งสรุปผลเข้า Telegram ทุกครั้งที่จบงาน

```
✅ Rank Math Bulk Connect
🖥 Server : ns5041423
🎛 Mode   : Mode 2: เลือกบาง cPanel
👥 cPanel Accounts: 3 accounts (เลือกจาก 47)
├ Total       : 250
├ ✅ Pass     : 245  (overwrite 200)
├ ✔️ Already  : 3
├ ❌ Fail     : 1
└ ⏭ NoPlugin : 1
⏱ ใช้เวลา : 5 นาที 32 วินาที
```

---

## ⚙️ ปรับแต่ง

แก้ค่าที่หัวไฟล์:

```bash
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN="..."
TELEGRAM_CHAT_ID="..."
MAX_JOBS=10            # parallel jobs
WP_TIMEOUT=25          # timeout WP-CLI ต่อ command
DEACT_TIMEOUT=8        # timeout deactivate API
MAX_RETRY=3            # max retry input ที่ Mode 2
```

---

## 📄 Config File

ตำแหน่ง default: `/root/.rankmath-connect.conf`

```bash
RM_USERNAME="username_ใหม่"
RM_EMAIL="email@gmail.com"
RM_API_KEY="xxxxxxxxxxxxxxx"
RM_PLAN="free"
RM_OLD_USERNAME="username_เก่า"     # สำหรับ deactivate
RM_OLD_API_KEY="xxxxxxxxxxxxxxx"   # API key เก่า
```

> เรียกใช้ custom config: `bash connect-account.sh /path/to/conf` หรือ `RANKMATH_CONF=/path bash connect-account.sh`

---

## 📁 Log Files

`/var/log/` — overwrite ทุกครั้งที่รัน

| File | เนื้อหา |
|---|---|
| `rankmath-connect.log` | log หลัก + summary |
| `rankmath-connect-pass.log` | เว็บที่ inject สำเร็จ |
| `rankmath-connect-already.log` | เว็บที่ใช้ account ใหม่อยู่แล้ว |
| `rankmath-connect-overwrite.log` | เว็บที่เปลี่ยน account |
| `rankmath-connect-fail.log` | เว็บที่ verify ไม่ผ่าน |
| `rankmath-connect-noplugin.log` | เว็บที่ไม่มี Rank Math plugin |

---

## ❌ Script จะ **ไม่** ทำสิ่งเหล่านี้

- ไม่ติดตั้ง Rank Math plugin (ถ้ายังไม่มี → skip)
- ไม่ activate plugin (ถ้า inactive → skip)
- ไม่แตะ Rank Math settings อื่น (Sitemap, SEO, Schema, ฯลฯ)
- ไม่สร้าง Rank Math account (ต้องสมัครบน rankmath.com ก่อน)

---

## 🔗 Related Repos

- [Litespeed-Object-Cache](https://github.com/AnonymousVS/Litespeed-Object-Cache) — Setup Object Cache → Redis
- [Litespeed-Purge-All](https://github.com/AnonymousVS/Litespeed-Purge-All) — Purge LiteSpeed cache
- [WP-Toolkit-CleanUP](https://github.com/AnonymousVS/WP-Toolkit-CleanUP) — ลบ default plugins/themes

---

## 📝 License

MIT

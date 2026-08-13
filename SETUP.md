# Menjalankan JalanKita di mesin baru

Repo ini menyimpan konfigurasi Apple Developer milik **satu** akun. Kalau kamu
bukan pemilik akun itu, ada 4 tempat yang harus diubah dulu — dan sebagian
besar **tidak gagal saat build**, jadi gampang terlewat.

## Yang harus diubah

| Tempat | Isi sekarang | Ganti jadi |
|---|---|---|
| Xcode → target **JalanKita Mac** & **JalanKita iOS** → Signing & Capabilities → Team | `6N4SKDX637` | Team ID kamu |
| Bundle Identifier kedua target | `com.ius.JalanKita-Mac` / `com.ius.JalanKita-iOS` | domain kamu |
| `JalanKita Mac/JalanKita Mac/JalanKita Mac.entitlements`<br>`JalanKita Mac/JalanKita iOS/JalanKita iOS.entitlements` | `iCloud.com.ius.JalanKita` | kontainer iCloud kamu |
| `JalanKitaKit/Sources/JalanKitaKit/CloudKit/CloudKitSchema.swift` → `containerIdentifier` | `iCloud.com.ius.JalanKita` | kontainer iCloud kamu (**harus sama persis** dengan entitlements di atas) |

Kontainer iCloud dibuat lewat Xcode (Signing & Capabilities → iCloud →
CloudKit → tombol `+`) atau di Apple Developer portal.

## Kenapa ini gampang terlewat

- **Team ID / Bundle ID salah** → gagal saat build atau saat signing. Kelihatan.
- **Kontainer iCloud salah** → **tidak ada error sama sekali.** App tetap
  ter-build, tetap jalan, tapi sinkronisasi diam-diam tidak menghasilkan apa pun,
  karena CloudKit menolak kontainer yang bukan milik tim penanda tangan. Kalau
  Sesi masuk selalu kosong padahal iPhone sudah merekam, periksa ini duluan.

Entitlements dan `CloudKitSchema.swift` harus menyebut string yang **sama
persis**. Beda satu huruf = gejalanya sama: senyap.

## Sisi Python

Tiga worker punya dependensi dan `.venv` sendiri-sendiri — lihat README
masing-masing:

- `CarDetection/README.md` — deteksi mobil/parkir (YOLO + YOLOP + MiDaS)
- `PythonWorker/README.md` — worker gangguan/disturbance
- `RoadDamage/README.md` — deteksi kerusakan jalan

`CarDetection` tidak bisa memakai ulang `.venv` milik `PythonWorker`; tumpukan
dependensinya beda jauh. App tetap bisa di-build dan dipakai untuk kerja UI
tanpa satu pun `.venv` terpasang — fitur yang butuh worker akan melapor di log,
bukan crash.

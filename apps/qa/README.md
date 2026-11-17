# QA Documentation — Times420s

Folder ini berisi semua dokumentasi testing untuk project Times420s.

## Struktur

```
qa/
├── README.md                    ← kamu di sini
├── test-plan.md                 ← strategi testing keseluruhan
├── test-cases/
│   ├── TC-AUTH.md               ← Authentication (login, logout, role)
│   ├── TC-MENU.md               ← Menu management (CRUD menu & kategori)
│   ├── TC-ORDER.md              ← Order management (buat, edit, proses order)
│   ├── TC-PAYMENT.md            ← Payment (kasir, QRIS, transfer)
│   ├── TC-SHIFT.md              ← Shift kasir (buka/tutup shift)
│   ├── TC-INVENTORY.md          ← Inventory (stok bahan baku)
│   ├── TC-PROMO.md              ← Promo & voucher
│   └── TC-CUSTOMER-MENU.md      ← Customer self-order via QR
└── bug-reports/
    └── .gitkeep
```

## Progress

| Module | Total TC | Pass | Fail | Belum Ditest |
|--------|----------|------|------|--------------|
| Authentication | 6 | - | - | 6 |
| Menu Management | 8 | - | - | 8 |
| Order Management | 7 | - | - | 7 |
| Payment | 5 | - | - | 5 |
| Shift | 4 | - | - | 4 |
| Inventory | 5 | - | - | 5 |
| Promo & Voucher | 5 | - | - | 5 |
| Customer Menu | 5 | - | - | 5 |
| **TOTAL** | **45** | **-** | **-** | **45** |

> Update tabel ini setiap kali kamu selesai testing satu sesi.

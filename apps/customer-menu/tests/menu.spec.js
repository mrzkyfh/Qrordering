import { expect, test } from '@playwright/test'

const currentMenu = [
  {
    id: 'menu-1',
    name: 'Kebab Ayam',
    description: 'Kebab isi ayam',
    price: 20000,
    image_url: null,
    category_id: 'cat-1',
    is_featured: true,
    sort_order: 1,
  },
  {
    id: 'menu-2',
    name: 'Es Kopi',
    description: 'Kopi dingin',
    price: 10000,
    image_url: null,
    category_id: 'cat-2',
    is_featured: false,
    sort_order: 2,
  },
]

const currentExtras = [
  {
    menu_item_id: 'menu-1',
    menu_extras: {
      id: 'extra-topping',
      name: 'Topping',
      type: 'optional',
      selection_type: 'multiple',
      sort_order: 1,
      menu_extra_options: [
        { id: 'opt-keju', name: 'Keju', price: 5000, sort_order: 1 },
        { id: 'opt-telur', name: 'Telur', price: 4000, sort_order: 2 },
        { id: 'opt-sosis', name: 'Sosis', price: 6000, sort_order: 3 },
      ],
    },
  },
]

async function installSupabaseMock(
  page,
  {
    cart = null,
    createError = null,
    failFirstCreate = false,
    missingIdempotencyRpc = false,
    missingSnapshotRpc = false,
    disableRandomUuid = false,
    coverUrl = null,
    allowNotes = true,
    extras = [],
    categories = null,
  } = {},
) {
  await page.route('**/vendor/supabase.js', route => route.abort())
  await page.addInitScript(
    ({
      menu,
      storedCart,
      orderError,
      failFirst,
      missingRpc,
      missingMenuSnapshot,
      withoutRandomUuid,
      customerMenuCoverUrl,
      allowMenuNotes,
      menuExtras,
      menuCategories,
    }) => {
      window.__rpcCalls = []
      window.__fromCalls = []
      window.__createAttempts = 0
      if (withoutRandomUuid) {
        Object.defineProperty(window.crypto, 'randomUUID', {
          value: undefined,
          configurable: true,
        })
      }
      if (storedCart) {
        localStorage.setItem('t420_cart_outlet-1', JSON.stringify(storedCart))
      }

      const responseFor = table => {
        if (table === 'v_outlets_public') {
          return {
            data: {
              id: 'outlet-1',
              name: 'QR Ordering',
              settings: {
                tax_active: true,
                tax_percent: 10,
                service_charge_percent: 2,
                customer_menu_cover_url: customerMenuCoverUrl,
                self_order_allow_notes: allowMenuNotes,
              },
            },
            error: null,
          }
        }
        if (table === 'menu_categories') {
          return {
            data: menuCategories || [
              { id: 'cat-1', name: 'Kebab', icon: '', sort_order: 1 },
              { id: 'cat-2', name: 'Minuman', icon: '', sort_order: 2 },
            ],
            error: null,
          }
        }
        if (table === 'menu_items') return { data: menu, error: null }
        if (table === 'menu_item_extras') return { data: menuExtras, error: null }
        return { data: [], error: null }
      }

      const builderFor = table => {
        const result = responseFor(table)
        const builder = {
          select: () => builder,
          eq: () => builder,
          in: () => builder,
          order: () => builder,
          single: async () => result,
          then: (resolve, reject) => Promise.resolve(result).then(resolve, reject),
        }
        return builder
      }

      window.supabase = {
        createClient: () => ({
          from: table => {
            window.__fromCalls.push(table)
            return builderFor(table)
          },
          rpc: async (name, args) => {
            window.__rpcCalls.push({ name, args })
            if (name === 'get_public_menu_snapshot') {
              if (missingMenuSnapshot) {
                return {
                  data: null,
                  error: {
                    code: 'PGRST202',
                    message: 'Could not find the function get_public_menu_snapshot',
                  },
                }
              }
              return {
                data: {
                  table: {
                    id: 'table-1',
                    outlet_id: 'outlet-1',
                    table_number: 'A1',
                    area: 'Dalam',
                  },
                  outlet: {
                    id: 'outlet-1',
                    name: 'QR Ordering',
                    settings: {
                      tax_active: true,
                      tax_percent: 10,
                      service_charge_percent: 2,
                      customer_menu_cover_url: customerMenuCoverUrl,
                      self_order_allow_notes: allowMenuNotes,
                    },
                  },
                  categories: menuCategories || [
                    { id: 'cat-1', name: 'Kebab', icon: '', sort_order: 1 },
                    { id: 'cat-2', name: 'Minuman', icon: '', sort_order: 2 },
                  ],
                  menu,
                  extras: menuExtras,
                },
                error: null,
              }
            }
            if (name === 'resolve_table_by_token') {
              return {
                data: {
                  id: 'table-1',
                  outlet_id: 'outlet-1',
                  table_number: 'A1',
                  area: 'Dalam',
                },
                error: null,
              }
            }
            if (name === 'create_self_order') {
              window.__createAttempts += 1
              if (missingRpc && args.p_request_id) {
                return {
                  data: null,
                  error: {
                    code: 'PGRST202',
                    message: 'Could not find the function create_self_order with p_request_id',
                  },
                }
              }
              if (failFirst && window.__createAttempts === 1) {
                return { data: null, error: { message: 'Failed to fetch' } }
              }
              return orderError
                ? { data: null, error: { message: orderError } }
                : {
                    data: {
                      order_id: '11111111-1111-4111-8111-111111111111',
                      order_number: 'ORD-001',
                      access_token: '22222222-2222-4222-8222-222222222222',
                    },
                    error: null,
                  }
            }
            if (name === 'find_loyalty_member_by_phone') {
              return {
                data: {
                  id: 'member-1',
                  name: 'Budi',
                  phone: '08123456789',
                  points: 100,
                },
                error: null,
              }
            }
            if (name === 'validate_loyalty_redeem') {
              return {
                data: { points_used: 10, discount_amount: 1000 },
                error: null,
              }
            }
            if (name === 'validate_promo_code') {
              return {
                data: {
                  promo_id: 'promo-1',
                  voucher_id: null,
                  discount_amount: 2000,
                  promo_name: 'Promo Hemat',
                },
                error: null,
              }
            }
            if (name === 'get_self_orders') return { data: [], error: null }
            return { data: null, error: null }
          },
        }),
      }
    },
    {
      menu: currentMenu,
      storedCart: cart,
      orderError: createError,
      failFirst: failFirstCreate,
      missingRpc: missingIdempotencyRpc,
      missingMenuSnapshot: missingSnapshotRpc,
      withoutRandomUuid: disableRandomUuid,
      customerMenuCoverUrl: coverUrl,
      allowMenuNotes: allowNotes,
      menuExtras: extras,
      menuCategories: categories,
    },
  )
}

async function openMenu(page, options) {
  await installSupabaseMock(page, options)
  await page.goto('/?token=valid-token')
  await expect(page.locator('#welcomeScreen')).toBeVisible({ timeout: 5_000 })
  await expect(page.locator('#initialNameOverlay')).toBeVisible()
  await page.locator('#initialCustomerName').fill('Budi')
  await page.getByRole('button', { name: 'Lanjut' }).click()
  await page.getByRole('button', { name: 'Makan di Tempat' }).click()
  await expect(page.locator('#app')).toBeVisible({ timeout: 5_000 })
}

test('tab kategori mengikuti urutan setting dan menu dibagi per kategori', async ({ page }) => {
  await openMenu(page, {
    categories: [
      { id: 'cat-2', name: 'Minuman', icon: '🥤', sort_order: 2 },
      { id: 'cat-1', name: 'Kebab', icon: '🌯', sort_order: 1 },
    ],
  })

  const categoryTabs = page.locator('#categoryTabs .category-tab')
  await expect(categoryTabs).toHaveText([
    'Semua Produk',
    'Kebab',
    'Minuman',
  ])
  await expect(categoryTabs.first()).toHaveAttribute('aria-current', 'true')

  const sections = page.locator('.menu-section:not(.recommendation-section)')
  await expect(sections).toHaveCount(2)
  await expect(sections.nth(0).getByRole('heading')).toHaveText('Kebab')
  await expect(sections.nth(0).locator('.menu-card')).toContainText('Kebab Ayam')
  await expect(sections.nth(1).getByRole('heading')).toHaveText('Minuman')
  await expect(sections.nth(1).locator('.menu-card')).toContainText('Es Kopi')

  await page.getByRole('button', { name: 'Minuman', exact: true }).click()
  await expect(categoryTabs.nth(2)).toHaveAttribute('aria-current', 'true')
  await expect(page.locator('#menu-category-cat-2')).toBeVisible()
})

test('produk unggulan muncul sebagai bagian rekomendasi dan tetap ada di kategorinya', async ({ page }) => {
  await openMenu(page)

  const recommendation = page.locator('#menu-recommendation')
  await expect(recommendation.getByRole('heading')).toHaveText('Rekomendasi Produk')
  await expect(recommendation.locator('.menu-card')).toHaveCount(1)
  await expect(recommendation).toContainText('Kebab Ayam')
  await expect(recommendation.locator('.featured-badge')).toHaveText('★ Unggulan')
  await expect(page.locator('#menu-category-cat-1')).toContainText('Kebab Ayam')
})

test('layar pembuka menampilkan outlet, meja, petunjuk, dan pilihan layanan', async ({ page }) => {
  const coverUrl = 'https://images.example.com/outlet.jpg'
  await page.route(coverUrl, route => route.fulfill({
    contentType: 'image/svg+xml',
    body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="100%" height="100%" fill="#eee"/></svg>',
  }))
  await installSupabaseMock(page, { coverUrl })
  await page.goto('/?token=valid-token')

  await expect(page.locator('#welcomeScreen')).toBeVisible({ timeout: 5_000 })
  await expect(page.locator('#welcomeOutletName')).toHaveText('QR Ordering')
  await expect(page.locator('#welcomeTableLabel')).toContainText('Meja A1')
  await expect(page.locator('#welcomeHeroImage')).toHaveAttribute('src', coverUrl)
  await expect(page.locator('#welcomeHeroImage')).toHaveCSS('object-fit', 'contain')
  await expect(page.locator('#welcomeHeroBackdrop')).toHaveAttribute('src', coverUrl)
  await expect(page.locator('#welcomeHeroBackdrop')).toHaveCSS('object-fit', 'cover')
  await expect(page.locator('.welcome-hero')).toHaveClass(/has-fitted-image/)
  await expect(page.locator('.welcome-hero')).toHaveCSS('aspect-ratio', '640 / 360')
  await expect(page.getByRole('heading', { name: 'Cara memesan' })).toBeVisible()
  await expect(page.locator('#initialNameOverlay')).toBeVisible()
  await expect(page.locator('#initialCustomerName')).toHaveAttribute('required', '')
  await expect(page.getByRole('button', { name: 'Makan di Tempat' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Bawa Pulang' })).toBeVisible()
  await expect(page.locator('#app')).toBeHidden()

  await page.locator('#welcomeHeroImage').dispatchEvent('error')
  await expect(page.locator('#welcomeHeroImage')).toBeHidden()
  await expect(page.locator('#welcomeHeroBackdrop')).toBeHidden()
})

test('layar pembuka tetap utuh pada ponsel sempit dan lebar', async ({ page }) => {
  await installSupabaseMock(page)

  for (const viewport of [
    { width: 320, height: 640 },
    { width: 430, height: 932 },
  ]) {
    await page.setViewportSize(viewport)
    await page.goto('/?token=valid-token')
    await expect(page.locator('#welcomeScreen')).toBeVisible({ timeout: 5_000 })

    const layout = await page.evaluate(() => {
      const serviceButtons = [...document.querySelectorAll('.welcome-service-btn')]
      const outletCard = document.querySelector('.welcome-outlet-card')
      return {
        viewportWidth: window.innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        card: outletCard?.getBoundingClientRect(),
        buttons: serviceButtons.map(button => button.getBoundingClientRect()),
      }
    })

    expect(layout.documentWidth).toBeLessThanOrEqual(layout.viewportWidth)
    expect(layout.card.x).toBeGreaterThanOrEqual(0)
    expect(layout.card.right).toBeLessThanOrEqual(layout.viewportWidth)
    for (const button of layout.buttons) {
      expect(button.x).toBeGreaterThanOrEqual(0)
      expect(button.right).toBeLessThanOrEqual(layout.viewportWidth)
      expect(button.height).toBeGreaterThanOrEqual(44)
    }
  }
})

test('jenis layanan tersimpan pada pesanan dan keranjangnya tidak tercampur', async ({ page }) => {
  await installSupabaseMock(page)
  await page.goto('/?token=valid-token')
  await expect(page.locator('#welcomeScreen')).toBeVisible({ timeout: 5_000 })

  await page.getByRole('button', { name: 'Lanjut' }).click()
  await expect(page.locator('#welcomeScreen')).toBeVisible()
  await expect(page.locator('#initialNameError')).toHaveText('Nama pemesan wajib diisi.')
  await page.locator('#initialCustomerName').fill('Budi')
  await page.getByRole('button', { name: 'Lanjut' }).click()

  await page.getByRole('button', { name: 'Makan di Tempat' }).click()
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await expect(page.locator('#fabCount')).toHaveText('1 item')

  await page.locator('#tableBadge').click()
  await page.getByRole('button', { name: 'Bawa Pulang' }).click()
  await expect(page.locator('#cartFab')).toBeHidden()
  await page.getByRole('button', { name: 'Tambah Es Kopi' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await expect(page.locator('#checkoutItems')).toContainText('Bawa Pulang')
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  const notes = await page.evaluate(() => window.__rpcCalls
    .find(call => call.name === 'create_self_order')?.args?.p_notes)
  expect(notes).toContain('Jenis layanan: Bawa Pulang')

  await page.getByRole('button', { name: 'Oke, Terima Kasih!' }).click()
  await page.locator('#tableBadge').click()
  await page.getByRole('button', { name: 'Makan di Tempat' }).click()
  await expect(page.locator('#fabCount')).toHaveText('1 item')
  await page.locator('#cartFabBtn').click()
  await expect(page.locator('#cartItems')).toContainText('Kebab Ayam')
  await expect(page.locator('#cartItems')).not.toContainText('Es Kopi')
})

test('build produksi memuat pustaka Supabase lokal tanpa CDN', async ({ page }) => {
  const pageErrors = []
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.goto('/')

  await expect(page.getByRole('heading', { name: 'Pindai Kode QR' })).toBeVisible()
  const hasLocalClient = await page.evaluate(
    () => typeof window.supabase?.createClient === 'function',
  )
  expect(hasLocalClient).toBe(true)
  expect(pageErrors).toEqual([])
})

test('QR wajib tersedia sebelum menu dibuka', async ({ page }) => {
  await installSupabaseMock(page)
  await page.goto('/')
  await expect(page.locator('#scanScreen')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Pindai Kode QR' })).toBeVisible()
})

test('menu QR dimuat lewat satu snapshot tanpa query tabel tambahan', async ({ page }) => {
  await openMenu(page)

  const calls = await page.evaluate(() => ({
    snapshot: window.__rpcCalls.filter(
      call => call.name === 'get_public_menu_snapshot',
    ).length,
    legacyResolve: window.__rpcCalls.filter(
      call => call.name === 'resolve_table_by_token',
    ).length,
    tables: window.__fromCalls,
  }))
  expect(calls.snapshot).toBe(1)
  expect(calls.legacyResolve).toBe(0)
  expect(calls.tables).toEqual([])
})

test('menu tetap terbuka saat snapshot RPC belum tersedia', async ({ page }) => {
  await openMenu(page, { missingSnapshotRpc: true })

  await expect(page.locator('#menu-category-cat-1').getByText('Kebab Ayam')).toBeVisible()
  const calls = await page.evaluate(() => ({
    snapshot: window.__rpcCalls.some(
      call => call.name === 'get_public_menu_snapshot',
    ),
    legacyResolve: window.__rpcCalls.some(
      call => call.name === 'resolve_table_by_token',
    ),
  }))
  expect(calls).toEqual({ snapshot: true, legacyResolve: true })
})

test('menu dapat dicari, ditambahkan, dan dikirim satu kali', async ({ page }) => {
  await openMenu(page)

  await expect(page.locator('#menu-category-cat-1').getByText('Kebab Ayam')).toBeVisible()
  await expect(page.locator('.menu-card').first()).toContainText('Kebab Ayam')
  await expect(page.locator('.menu-card').first().getByText('Unggulan')).toBeVisible()
  await page.getByRole('button', { name: 'Cari menu' }).click()
  await page.getByRole('searchbox', { name: 'Cari menu' }).fill('kopi')
  await expect(page.getByText('Es Kopi')).toBeVisible()
  await expect(page.getByText('Kebab Ayam')).toBeHidden()
  await page.getByRole('searchbox', { name: 'Cari menu' }).fill('')

  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await expect(page.locator('#cartFab')).toBeVisible()
  await expect(page.locator('#fabCount')).toHaveText('1 item')

  await page.locator('#cartFabBtn').click()
  await expect(page.getByRole('dialog', { name: 'Keranjang' })).toBeVisible()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  await expect(page.getByRole('dialog', { name: 'Pesanan Terkirim!' })).toBeVisible()
  await expect(page.locator('#successNum')).toHaveText('ORD-001')
  const submitted = await page.evaluate(
    () => window.__rpcCalls.filter(call => call.name === 'create_self_order'),
  )
  expect(submitted).toHaveLength(1)
  expect(submitted[0].args.p_customer_name).toBe('Budi')
})

test('catatan tersimpan per menu dan terpisah dari catatan pesanan', async ({ page }) => {
  await openMenu(page)

  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Tambah catatan untuk Kebab Ayam' }).click()
  await page.locator('#itemNoteInput').fill('Tanpa bawang, sambal dipisah')
  await page.getByRole('button', { name: 'Simpan Catatan' }).click()

  await expect(page.locator('#cartItems')).toContainText('Tanpa bawang, sambal dipisah')
  await page.getByRole('button', { name: 'Tutup keranjang' }).click()
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await expect(page.locator('.cart-item')).toHaveCount(2)

  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await expect(page.locator('#checkoutItems')).toContainText('Tanpa bawang, sambal dipisah')
  await page.locator('#orderNotes').fill('Antar semua menu bersamaan')
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  const request = await page.evaluate(() => window.__rpcCalls
    .find(call => call.name === 'create_self_order')?.args)
  expect(request.p_items).toHaveLength(2)
  expect(request.p_items.map(item => item.notes)).toEqual([
    'Tanpa bawang, sambal dipisah',
    null,
  ])
  expect(request.p_notes).toContain('Antar semua menu bersamaan')
  expect(request.p_notes).not.toContain('Tanpa bawang, sambal dipisah')
})

test('topping dapat diganti dan ditambah tanpa menghapus item keranjang', async ({ page }) => {
  await openMenu(page, { extras: currentExtras })

  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.getByLabel('Keju').check()
  await page.getByRole('button', { name: 'Tambah ke Pesanan' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Tambah catatan untuk Kebab Ayam' }).click()
  await page.locator('#itemNoteInput').fill('Saus dipisah')
  await page.getByRole('button', { name: 'Simpan Catatan' }).click()

  await page.getByRole('button', { name: 'Ubah pilihan tambahan untuk Kebab Ayam' }).click()
  await expect(page.getByLabel('Keju')).toBeChecked()
  await page.getByLabel('Keju').uncheck()
  await page.getByLabel('Telur').check()
  await page.getByLabel('Sosis').check()
  await page.getByRole('button', { name: 'Simpan Pilihan' }).click()

  await expect(page.locator('.cart-item')).toHaveCount(1)
  await expect(page.locator('#cartItems')).not.toContainText('Keju')
  await expect(page.locator('#cartItems')).toContainText('Telur, Sosis')
  await expect(page.locator('#cartItems')).toContainText('Saus dipisah')
  await expect(page.locator('#cartTotal')).toHaveText(/Rp\s*33\.600/)

  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()
  const submittedItem = await page.evaluate(() => window.__rpcCalls
    .find(call => call.name === 'create_self_order')?.args?.p_items?.[0])
  expect(submittedItem.notes).toBe('Saus dipisah')
  expect(submittedItem.options.map(option => option.option_name)).toEqual([
    'Telur',
    'Sosis',
  ])
  expect(submittedItem.unit_price).toBe(30000)
})

test('pilihan extra lama tidak bocor dan kontrol terpilih selalu masuk keranjang', async ({ page }) => {
  const sizeExtra = [{
    menu_item_id: 'menu-1',
    menu_extras: {
      id: 'extra-size',
      name: 'Extra Meat',
      type: 'optional',
      selection_type: 'single',
      sort_order: 1,
      menu_extra_options: [
        { id: 'opt-medium', name: 'Medium', price: 13000, sort_order: 1 },
        { id: 'opt-large', name: 'Large', price: 17500, sort_order: 2 },
      ],
    },
  }]
  await openMenu(page, { extras: sizeExtra })

  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.getByLabel('Medium').check()
  await page.getByRole('button', { name: 'Tambah ke Pesanan' }).click()

  // Penambahan porsi baru tidak boleh mewarisi radio dari item sebelumnya.
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await expect(page.getByLabel('Medium')).not.toBeChecked()

  // Simulasikan Safari menampilkan radio terpilih tanpa mengirim event change.
  await page.getByLabel('Medium').evaluate(input => { input.checked = true })
  await page.getByRole('button', { name: 'Tambah ke Pesanan' }).click()
  await page.locator('#cartFabBtn').click()

  const rows = page.locator('.cart-item')
  await expect(rows).toHaveCount(2)
  await expect(rows.nth(0)).toContainText('Medium')
  await expect(rows.nth(1)).toContainText('Medium')
  await expect(rows.nth(0)).toContainText(/Rp\s*33\.000/)
  await expect(rows.nth(1)).toContainText(/Rp\s*33\.000/)
})

test('ID baris keranjang lama yang duplikat dinormalisasi sebelum topping diedit', async ({ page }) => {
  await openMenu(page, {
    extras: currentExtras,
    cart: [
      {
        id: 'menu-1',
        cartId: 'baris-sama',
        quantity: 1,
        selectedExtras: [{ menuExtraOptionId: 'opt-keju' }],
        notes: 'Pesanan pertama',
      },
      {
        id: 'menu-1',
        cartId: 'baris-sama',
        quantity: 1,
        selectedExtras: [{ menuExtraOptionId: 'opt-telur' }],
        notes: 'Pesanan kedua',
      },
    ],
  })

  await page.locator('#cartFabBtn').click()
  const rows = page.locator('.cart-item')
  await expect(rows).toHaveCount(2)
  const cartIds = await rows.evaluateAll(items => items.map(item =>
    item.querySelector('[data-action="extras"]')?.dataset.cartId,
  ))
  expect(new Set(cartIds).size).toBe(2)

  await rows.nth(1).getByRole('button', {
    name: 'Ubah pilihan tambahan untuk Kebab Ayam',
  }).click()
  await page.getByLabel('Telur').uncheck()
  await page.getByLabel('Sosis').check()
  await page.getByRole('button', { name: 'Simpan Pilihan' }).click()

  await expect(rows.nth(0)).toContainText('Keju')
  await expect(rows.nth(0)).not.toContainText('Sosis')
  await expect(rows.nth(1)).toContainText('Sosis')
  await expect(rows.nth(1)).not.toContainText('Telur')
})

test('keranjang lama mematuhi topping wajib dan pilihan tunggal terbaru', async ({ page }) => {
  const requiredExtras = [{
    menu_item_id: 'menu-1',
    menu_extras: {
      id: 'extra-size',
      name: 'Ukuran',
      type: 'required',
      selection_type: 'single',
      sort_order: 1,
      menu_extra_options: [
        { id: 'opt-small', name: 'Kecil', price: 0, sort_order: 1 },
        { id: 'opt-large', name: 'Besar', price: 5000, sort_order: 2 },
      ],
    },
  }]
  await openMenu(page, {
    extras: requiredExtras,
    cart: [
      { id: 'menu-1', cartId: 'tanpa-wajib', quantity: 1, selectedExtras: [] },
      {
        id: 'menu-1',
        cartId: 'dua-ukuran',
        quantity: 1,
        selectedExtras: [
          { menuExtraOptionId: 'opt-small' },
          { menuExtraOptionId: 'opt-large' },
        ],
      },
    ],
  })

  await expect(page.locator('#fabCount')).toHaveText('1 item')
  const stored = await page.evaluate(() => JSON.parse(
    localStorage.getItem('t420_cart_outlet-1_table-1_dine_in'),
  ))
  expect(stored).toHaveLength(1)
  expect(stored[0].selectedExtras).toHaveLength(1)
  expect(stored[0].selectedExtras[0].menuExtraOptionId).toBe('opt-small')
})

test('opsi tambahan basi atau hasil manipulasi tidak memenuhi pilihan wajib', async ({ page }) => {
  const requiredExtras = [{
    menu_item_id: 'menu-1',
    menu_extras: {
      id: 'extra-size',
      name: 'Ukuran',
      type: 'required',
      selection_type: 'single',
      sort_order: 1,
      menu_extra_options: [
        { id: 'opt-small', name: 'Kecil', price: 0, sort_order: 1 },
        { id: 'opt-large', name: 'Besar', price: 5000, sort_order: 2 },
      ],
    },
  }]
  await openMenu(page, { extras: requiredExtras })

  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  const firstChoice = page.locator('#extrasBody input').first()
  await firstChoice.evaluate(input => {
    input.dataset.option = 'opt-sudah-dihapus'
    input.value = 'opt-sudah-dihapus'
    input.checked = true
    input.dispatchEvent(new Event('change', { bubbles: true }))
  })

  await expect(firstChoice).not.toBeChecked()
  await expect(page.locator('#extrasConfirmBtn')).toBeDisabled()
  await expect(page.locator('#toast')).toContainText(
    'Pilihan tambahan sudah tidak tersedia',
  )

  await page.getByLabel('Besar').check()
  await expect(page.locator('#extrasConfirmBtn')).toBeEnabled()
  await page.getByRole('button', { name: 'Tambah ke Pesanan' }).click()
  await page.locator('#cartFabBtn').click()
  await expect(page.locator('#cartItems')).toContainText('Besar')
})

test('perubahan keranjang membatalkan promo agar total tidak memakai nilai lama', async ({ page }) => {
  await openMenu(page)
  await page.getByRole('button', { name: 'Tambah Es Kopi' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.locator('#promoCodeInput').fill('HEMAT')
  await page.locator('#applyPromoBtn').click()
  await expect(page.locator('#applyPromoBtn')).toHaveText('Hapus')

  await page.getByRole('button', { name: 'Kembali ke keranjang' }).click()
  await page.locator('.cart-item [data-action="inc"]').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()

  await expect(page.locator('#applyPromoBtn')).toHaveText('Pakai')
  await expect(page.locator('#promoFeedback')).toContainText(
    'Keranjang berubah. Terapkan ulang kode promo.',
  )
})

test('jumlah item keranjang lama dibatasi dan tidak dapat melewati batas', async ({ page }) => {
  await openMenu(page, {
    cart: [{ id: 'menu-2', cartId: 'qty-lama', quantity: 999 }],
  })
  await expect(page.locator('#fabCount')).toHaveText('100 item')
  await page.locator('#cartFabBtn').click()
  await page.locator('.cart-item [data-action="inc"]').click()
  await expect(page.locator('.cart-item .qty-num')).toHaveText('100')
  await expect(page.locator('#toast')).toContainText('Maksimal 100 porsi')
})

test('catatan menu disembunyikan saat pengaturan outlet menonaktifkannya', async ({ page }) => {
  await openMenu(page, { allowNotes: false })
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()

  await expect(page.locator('.btn-item-note')).toHaveCount(0)
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await expect(page.locator('#orderNotesGroup')).toBeHidden()
})

test('keranjang lama memakai harga terbaru dan membuang menu yang sudah dihapus', async ({ page }) => {
  await openMenu(page, {
    cart: [
      { id: 'menu-1', name: 'Nama Lama', price: 1, quantity: 2 },
      { id: 'menu-dihapus', name: 'Menu Dihapus', price: 1, quantity: 50 },
    ],
  })

  await expect(page.locator('#fabCount')).toHaveText('2 item')
  await expect(page.locator('#fabTotal')).toHaveText(/Rp\s*40\.000/)
  await page.locator('#cartFabBtn').click()
  await expect(page.locator('#cartItems').getByText('Kebab Ayam')).toBeVisible()
  await expect(page.getByText('Menu Dihapus')).toHaveCount(0)
})

test('gangguan jaringan dapat dicoba ulang dengan ID sama pada WebView lama', async ({ page }) => {
  await openMenu(page, { failFirstCreate: true, disableRandomUuid: true })
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()

  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()
  await expect(page.locator('#toast')).toContainText('Koneksi bermasalah')
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()
  await expect(page.getByRole('dialog', { name: 'Pesanan Terkirim!' })).toBeVisible()

  const requestIds = await page.evaluate(() =>
    window.__rpcCalls
      .filter(call => call.name === 'create_self_order')
      .map(call => call.args.p_request_id),
  )
  expect(requestIds).toHaveLength(2)
  expect(requestIds[0]).toMatch(/^[0-9a-f-]{36}$/i)
  expect(requestIds[1]).toBe(requestIds[0])
})

test('frontend tetap dapat memesan selama migrasi idempotensi belum aktif', async ({ page }) => {
  await openMenu(page, { missingIdempotencyRpc: true })
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  await expect(page.getByRole('dialog', { name: 'Pesanan Terkirim!' })).toBeVisible()
  const attempts = await page.evaluate(() =>
    window.__rpcCalls.filter(call => call.name === 'create_self_order'),
  )
  expect(attempts).toHaveLength(3)
  expect(attempts[0].args.p_request_id).toMatch(/^[0-9a-f-]{36}$/i)
  expect(attempts[1].args.p_request_id).toBe(attempts[0].args.p_request_id)
  expect(attempts[2].args.p_request_id).toBeUndefined()
})

test('member earning-only ikut ke order tanpa membuka lookup atau penukaran poin', async ({ page }) => {
  await openMenu(page)
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()

  await expect(page.locator('#memberPhoneInput')).toHaveCount(1)
  await expect(page.locator('#memberLookupBtn')).toHaveCount(0)
  await expect(page.locator('#redeemInput')).toHaveCount(0)
  await expect(page.locator('#redeemBtn')).toHaveCount(0)
  await page.locator('#memberPhoneInput').fill('+62 812-3456-789')

  await page.locator('#promoCodeInput').fill('HEMAT')
  await page.locator('#applyPromoBtn').click()
  await expect(page.locator('#applyPromoBtn')).toHaveText('Hapus')
  await page.locator('#applyPromoBtn').click()
  await expect(page.locator('#applyPromoBtn')).toHaveText('Pakai')

  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()
  await expect(page.getByRole('dialog', { name: 'Pesanan Terkirim!' })).toBeVisible()

  const { counts, orderArgs } = await page.evaluate(() => ({
    counts: Object.fromEntries(
      ['find_loyalty_member_by_phone', 'validate_loyalty_redeem', 'validate_promo_code']
        .map(name => [name, window.__rpcCalls.filter(call => call.name === name).length]),
    ),
    orderArgs: window.__rpcCalls.find(call => call.name === 'create_self_order')?.args,
  }))
  expect(counts).toEqual({
    find_loyalty_member_by_phone: 0,
    validate_loyalty_redeem: 0,
    validate_promo_code: 1,
  })
  expect(orderArgs.p_member_phone).toBe('+62 812-3456-789')
  expect(orderArgs.p_member_id).toBeUndefined()
  expect(orderArgs.p_redeem_points).toBeUndefined()
})

test('nomor member tidak dibuang diam-diam bila backend member belum tersedia', async ({ page }) => {
  await openMenu(page, { missingIdempotencyRpc: true })
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.locator('#memberPhoneInput').fill('08123456789')
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  await expect(page.locator('#toast')).toContainText('Fitur member sedang disiapkan')
  await expect(page.getByRole('dialog', { name: 'Pesanan Terkirim!' })).toBeHidden()
  const attempts = await page.evaluate(() =>
    window.__rpcCalls.filter(call => call.name === 'create_self_order'),
  )
  expect(attempts).toHaveLength(1)
  expect(attempts[0].args.p_member_phone).toBe('08123456789')
})

test('nomor member yang belum valid ditolak sebelum membuat order', async ({ page }) => {
  await openMenu(page)
  await page.getByRole('button', { name: 'Tambah Kebab Ayam' }).click()
  await page.locator('#cartFabBtn').click()
  await page.getByRole('button', { name: 'Pesan Sekarang' }).click()
  await page.locator('#memberPhoneInput').fill('123')
  await page.getByRole('button', { name: 'Kirim Pesanan' }).click()

  await expect(page.locator('#toast')).toContainText('Nomor HP member belum valid')
  const attempts = await page.evaluate(() =>
    window.__rpcCalls.filter(call => call.name === 'create_self_order'),
  )
  expect(attempts).toHaveLength(0)
})

test('riwayat pesanan hanya dikirim dengan token akses dan mengabaikan ID lama', async ({ page }) => {
  await openMenu(page)
  await page.evaluate(() => {
    localStorage.setItem('t420_orders_outlet-1', JSON.stringify([
      '11111111-1111-4111-8111-111111111111',
      {
        id: '22222222-2222-4222-8222-222222222222',
        access_token: '33333333-3333-4333-8333-333333333333',
      },
      {
        id: '44444444-4444-4444-8444-444444444444',
        access_token: 'bukan-token-valid',
      },
    ]))
  })
  await page.reload()
  await expect(page.locator('#welcomeScreen')).toBeVisible({ timeout: 5_000 })
  await page.locator('#initialCustomerName').fill('Budi')
  await page.getByRole('button', { name: 'Lanjut' }).click()
  await page.getByRole('button', { name: 'Makan di Tempat' }).click()
  await expect(page.locator('#historyBtn')).toBeVisible()
  await page.locator('#historyBtn').click()

  const calls = await page.evaluate(() =>
    window.__rpcCalls.filter(call => call.name === 'get_self_orders'),
  )
  expect(calls).toHaveLength(1)
  expect(calls[0].args.p_orders).toEqual([
    {
      id: '22222222-2222-4222-8222-222222222222',
      access_token: '33333333-3333-4333-8333-333333333333',
    },
  ])
})

test('seluruh tombol terlihat memiliki nama, tipe, dan tidak ada overflow halaman', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 700 })
  await openMenu(page)

  const violations = await page.locator('button:visible').evaluateAll(buttons =>
    buttons.flatMap((button, index) => {
      const name = (
        button.getAttribute('aria-label')
        || button.textContent
        || ''
      ).trim()
      const issues = []
      if (!name) issues.push('tanpa nama')
      if (button.getAttribute('type') !== 'button') issues.push('type bukan button')
      return issues.length ? [`#${index + 1}: ${issues.join(', ')}`] : []
    }),
  )
  expect(violations).toEqual([])

  const sizes = await page.evaluate(() => ({
    page: document.documentElement.scrollWidth,
    viewport: window.innerWidth,
  }))
  expect(sizes.page).toBeLessThanOrEqual(sizes.viewport)
})

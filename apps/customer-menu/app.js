// ── Config ────────────────────────────────────────────────
const SUPABASE_URL     = 'https://yjmrabgpxjbunwtsiavs.supabase.co'
const SUPABASE_ANON_KEY = 'sb_publishable_K_soJ1CoHgv-JPGViFz7jQ_6EpgZgoA'

// Customer menu SELALU anon (pelanggan scan QR). persistSession:false →
// abaikan sesi login apa pun yang mungkin tersimpan di browser (mis. owner-panel
// di origin sama), supaya insert order tidak dieksekusi sebagai user authenticated
// (yang ditolak RLS karena outlet tak cocok). Tanpa ini: "bisa di satu device,
// gagal di device lain" tergantung ada/tidaknya sesi login.
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
})

// ── State ─────────────────────────────────────────────────
const state = {
    outlet: null,
    table: null,
    tableToken: null,
    orderMode: null,
    paymentMethod: 'qris',
    customerName: '',
    categories: [],
    menu: [],
    cart: [],
    selectedCat: 'all',
    extrasLookup: {},    // itemId → MenuExtra[]
    _extrasPending: null, // item being configured in extras modal
    _extrasSelections: {}, // extraId → Set<optionId>
    _extrasEditingCartId: null, // existing cart line being edited
    _notePendingCartId: null,
    promoCode: null,
    promoId: null,
    voucherId: null,
    discountAmount: 0,
    promoName: null,
    productPromos: [],
    orderRequestId: null,
}

const ORDER_MODES = {
    dine_in: { label: 'Makan di Tempat', shortLabel: 'Dine In' },
    pickup:  { label: 'Bawa Pulang', shortLabel: 'Pick Up' },
}

const MENU_SNAPSHOT_TTL_MS = 60_000
const ITEM_NOTE_MAX_LENGTH = 1000
const MAX_CART_LINES = 50
const MAX_ITEM_QUANTITY = 100
const MAX_OPTIONS_PER_ITEM = 30

function itemNotesAllowed() {
    return state.outlet?.settings?.self_order_allow_notes !== false
}

function normalizeItemNote(value) {
    const note = String(value || '').trim().slice(0, ITEM_NOTE_MAX_LENGTH)
    return note || null
}

function itemHasNote(item) {
    return Boolean(normalizeItemNote(item?.notes))
}

function applyNotesSetting() {
    const allowed = itemNotesAllowed()
    el('orderNotesGroup').classList.toggle('hidden', !allowed)
    el('cartNotesGroup').classList.toggle('hidden', !allowed)
    if (!allowed) el('orderNotes').value = ''
    if (!allowed) el('cartNotes').value = ''
}

function isMissingMenuSnapshotRpc(error) {
    if (!error) return false
    const message = String(error.message || error)
    return error.code === 'PGRST202'
        || message.includes('get_public_menu_snapshot')
        || message.includes('schema cache')
}

function menuSnapshotCacheKey(token) {
    return `t420_menu_snapshot_v2_${token}`
}

function readMenuSnapshotCache(token) {
    try {
        const raw = localStorage.getItem(menuSnapshotCacheKey(token))
        if (!raw) return null
        const cached = JSON.parse(raw)
        if (!cached?.savedAt || Date.now() - cached.savedAt > MENU_SNAPSHOT_TTL_MS) {
            localStorage.removeItem(menuSnapshotCacheKey(token))
            return null
        }
        return cached.data?.table && cached.data?.outlet ? cached.data : null
    } catch {
        return null
    }
}

function writeMenuSnapshotCache(token, data) {
    try {
        localStorage.setItem(
            menuSnapshotCacheKey(token),
            JSON.stringify({ savedAt: Date.now(), data }),
        )
    } catch {
        // Cache hanya optimasi; private mode/storage penuh tidak boleh
        // menghalangi pelanggan membuka menu.
    }
}

async function loadLegacyMenuSnapshot(token) {
    const { data: tableRow, error: tableErr } = await sb
        .rpc('resolve_table_by_token', { p_token: token })
    if (tableErr || !tableRow) return null

    const { data: outletRow, error: outletErr } = await sb
        .from('v_outlets_public')
        .select('id, name, address, phone, city, logo_url, settings')
        .eq('id', tableRow.outlet_id)
        .single()
    if (outletErr || !outletRow) return null

    const [catRes, menuRes] = await Promise.all([
        sb.from('menu_categories')
          .select('id, name, icon, sort_order')
          .eq('outlet_id', outletRow.id)
          .eq('is_active', true)
          .order('sort_order'),
        sb.from('menu_items')
          .select('id, name, description, price, image_url, category_id, is_featured, sort_order')
          .eq('outlet_id', outletRow.id)
          .eq('is_available', true)
          .eq('is_active', true)
          .eq('show_in_qr_menu', true)
          .order('is_featured', { ascending: false })
          .order('sort_order'),
    ])
    if (catRes.error) throw catRes.error
    if (menuRes.error) throw menuRes.error

    // Legacy fallback is only used while migration 169 rolls out. Scope the
    // relation by the already-resolved outlet/menu IDs so an anonymous client
    // cannot enumerate extras from other outlets through PostgREST.
    const menuIds = (menuRes.data || []).map(row => row.id).filter(Boolean)
    const extrasRes = menuIds.length
        ? await sb.from('menu_item_extras')
            .select('menu_item_id, menu_extras(id, name, type, selection_type, sort_order, outlet_id, menu_extra_options(id, name, price, sort_order))')
            .in('menu_item_id', menuIds)
            .eq('menu_extras.outlet_id', outletRow.id)
            .eq('menu_extras.is_active', true)
            .order('menu_extras(sort_order)')
        : { data: [], error: null }
    if (extrasRes.error) throw extrasRes.error

    return {
        table: tableRow,
        outlet: outletRow,
        categories: catRes.data || [],
        menu: menuRes.data || [],
        extras: extrasRes.data || [],
    }
}

async function loadMenuSnapshot(token) {
    const cached = readMenuSnapshotCache(token)
    if (cached) return cached

    const { data, error } = await sb.rpc('get_public_menu_snapshot', {
        p_token: token,
    })
    if (!error && data?.table && data?.outlet) {
        writeMenuSnapshotCache(token, data)
        return data
    }
    if (error && !isMissingMenuSnapshotRpc(error)) throw error

    // Kompatibilitas singkat selama database dan frontend belum terdeploy
    // pada detik yang sama. Jalur ini dapat dihapus setelah semua environment
    // sudah memiliki migration 169.
    const legacy = await loadLegacyMenuSnapshot(token)
    if (legacy) writeMenuSnapshotCache(token, legacy)
    return legacy
}

// ── Init ──────────────────────────────────────────────────
async function init() {
    const params = new URLSearchParams(window.location.search)
    const token  = params.get('token')

    if (!token) { showScanScreen(); return }

    try {
        const snapshot = await loadMenuSnapshot(token)
        if (!snapshot) {
            showError('QR code tidak valid atau meja tidak aktif.')
            return
        }
        const tableRow = snapshot.table
        const outletRow = snapshot.outlet

        state.tableToken = token
        state.table  = tableRow
        state.outlet = outletRow
        const promoResult = await sb.rpc('get_public_product_promos', { p_token: token })
        state.productPromos = promoResult.error ? [] : (promoResult.data || [])
        applyNotesSetting()

        // Tombol Riwayat muncul kalau outlet ini pernah punya pesanan tersimpan
        if (rememberedOrders().length > 0) el('historyBtn').classList.remove('hidden')

        // Show outlet name on splash
        el('splashOutletName').textContent = state.outlet.name || 'E-Menu'
        requestAnimationFrame(() => el('splashOutletName').classList.add('show'))

        const snapshotMenu = [...(snapshot.menu || [])]
        const visibleCategoryIds = new Set(snapshotMenu.map(item => item.category_id).filter(Boolean))
        state.categories = [...(snapshot.categories || [])]
          .filter(category => visibleCategoryIds.has(category.id))
          .sort((a, b) => {
            const order = (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0)
            return order || String(a.name || '').localeCompare(String(b.name || ''), 'id')
          })
        state.menu       = snapshotMenu.sort((a, b) => {
            const featured = Number(Boolean(b.is_featured)) - Number(Boolean(a.is_featured))
            return featured || (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0)
        })

        // Build lookup: itemId → active extras with options
        state.extrasLookup = {}
        for (const row of (snapshot.extras || [])) {
            const extra = row.menu_extras
            if (!extra) continue
            const itemId = row.menu_item_id
            if (!state.extrasLookup[itemId]) state.extrasLookup[itemId] = []
            state.extrasLookup[itemId].push(extra)
        }

        // Render header & welcome info
        el('outletName').textContent = state.outlet.name || 'E-Menu'
        renderWelcome()
        updateServiceUi()

        renderCategories()
        renderMenu()
        updateCartBadge()
        renderCartItems()
        updateCartFooter()
        updateFab()

        // Tunggu animasi splash nama outlet selesai baru masuk app
        setTimeout(() => showWelcome({ afterSplash: true }), 900)

    } catch (err) {
        console.error(err)
        showError('Gagal memuat menu. Coba scan ulang QR code.')
    }
}

// ── Render categories ──────────────────────────────────────
function renderCategories() {
    const tabs = el('categoryTabs')
    const validSelection = state.selectedCat === 'all'
        || state.categories.some(category => category.id === state.selectedCat)
    if (!validSelection) state.selectedCat = 'all'

    tabs.innerHTML = ''
    const categories = [{ id: 'all', name: 'Semua' }, ...state.categories]
    for (const category of categories) {
        const button = document.createElement('button')
        button.type = 'button'
        button.className = 'category-tab'
        button.dataset.categoryId = category.id
        button.textContent = category.name
        button.setAttribute('aria-current', String(category.id === state.selectedCat))
        button.addEventListener('click', () => selectCat(category.id))
        tabs.appendChild(button)
    }
}

function selectCat(id) {
    state.selectedCat = id
    for (const button of el('categoryTabs').querySelectorAll('.category-tab')) {
        button.setAttribute('aria-current', String(button.dataset.categoryId === id))
    }
    const target = id === 'all'
        ? el('menuGrid')
        : document.getElementById(`menu-category-${id}`)
    target?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function toggleMenuSearch(forceOpen = null) {
    const wrap = el('searchWrap')
    const button = el('searchToggleBtn')
    const shouldOpen = forceOpen == null
        ? wrap.classList.contains('hidden')
        : Boolean(forceOpen)
    wrap.classList.toggle('hidden', !shouldOpen)
    button.setAttribute('aria-expanded', String(shouldOpen))
    if (shouldOpen) {
        el('searchInput').focus()
    } else if (el('searchInput').value) {
        el('searchInput').value = ''
        renderMenu()
    }
}

function appendMenuSection(container, { id, title, items, recommendation = false }) {
    if (items.length === 0) return
    const section = document.createElement('section')
    section.className = `menu-section${recommendation ? ' recommendation-section' : ''}`
    section.id = id
    section.setAttribute('aria-labelledby', `${id}-title`)

    const heading = document.createElement('h2')
    heading.className = 'menu-section-title'
    heading.id = `${id}-title`
    heading.textContent = title
    section.appendChild(heading)

    const sectionGrid = document.createElement('div')
    sectionGrid.className = 'menu-grid'
    for (const item of items) {
        sectionGrid.appendChild(createCard(item, { recommendation }))
    }
    section.appendChild(sectionGrid)
    container.appendChild(section)
}

function promoForItem(itemId) {
    return state.productPromos.find(promo =>
        Array.isArray(promo.menu_item_ids) && promo.menu_item_ids.includes(itemId)) || null
}

function promoDiscount(promo, eligibleSubtotal) {
    if (!promo || eligibleSubtotal <= 0) return 0
    if (promo.type === 'percentage') {
        const raw = Math.round(eligibleSubtotal * Number(promo.value || 0) / 100)
        return promo.max_discount == null ? raw : Math.min(raw, Number(promo.max_discount))
    }
    if (promo.type === 'fixed') return Math.min(Number(promo.value || 0), eligibleSubtotal)
    return 0
}

function promoPriceForItem(item, promo) {
    return Math.max(0, Number(item.price) - promoDiscount(promo, Number(item.price)))
}

function appendPromoBanner(container, promo, item) {
    if (!promo || !item) return
    const promoPrice = promoPriceForItem(item, promo)
    const banner = document.createElement('section')
    banner.className = 'promo-banner'
    banner.setAttribute('aria-label', 'Promo hari ini')
    banner.innerHTML = `
        <div class="promo-copy">
            <span>${esc(promo.name || 'PROMO HARI INI')}</span>
            <strong>${esc(item.name)}</strong>
            <b>${fmt(promoPrice)} <del>${fmt(item.price)}</del></b>
        </div>
        <button type="button" data-action="add" data-id="${esc(item.id)}" aria-label="Pilih ${esc(item.name)}">Pilih</button>`
    container.appendChild(banner)
}

// ── Render menu grouped by category ───────────────────────
function renderMenu() {
    const search = el('searchInput').value.toLowerCase().trim()
    const catalog = el('menuGrid')

    let items = state.menu
    if (search) items = items.filter(i => i.name.toLowerCase().includes(search)
                                      || (i.description || '').toLowerCase().includes(search))

    catalog.innerHTML = ''
    if (items.length === 0) {
        catalog.innerHTML = '<p class="empty-grid">Tidak ada menu ditemukan</p>'
        return
    }

    if (!search) {
        const promo = state.productPromos[0]
        const promoItem = promo && items.find(item => promo.menu_item_ids?.includes(item.id))
        appendPromoBanner(catalog, promo, promoItem)
    }

    const categorizedIds = new Set()
    for (const category of state.categories) {
        const categoryItems = items.filter(item => item.category_id === category.id)
        if (categoryItems.length === 0) continue
        categorizedIds.add(category.id)
        appendMenuSection(catalog, {
            id: `menu-category-${category.id}`,
            title: category.name,
            items: categoryItems,
        })
    }

    const uncategorized = items.filter(item => !categorizedIds.has(item.category_id))
    appendMenuSection(catalog, {
        id: 'menu-category-other',
        title: 'Lainnya',
        items: uncategorized,
    })
}

function createCard(item, { recommendation = false } = {}) {
    const hasExtras = (state.extrasLookup[item.id] || []).length > 0
    const cartEntries = state.cart.filter(c => c.id === item.id)
    const qty = cartEntries.reduce((s, c) => s + c.quantity, 0)
    const initials = item.name.substring(0, 2).toUpperCase()
    const promo = promoForItem(item.id)
    const promoPrice = promo ? promoPriceForItem(item, promo) : null

    const card = document.createElement('div')
    card.className = `menu-card${recommendation ? ' recommendation-card' : ''}`
    card.dataset.id = item.id
    const actionContext = recommendation ? 'rekomendasi ' : ''

    // Items with extras always show "+ Tambah" to allow multiple selections
    const ctrlHtml = (qty === 0 || hasExtras)
        ? `<button type="button" class="btn-add" data-action="add" data-id="${esc(item.id)}" aria-label="Tambah ${actionContext}${esc(item.name)}">+</button>`
        : `<div class="qty-ctrl">
               <button type="button" class="btn-qty" data-action="dec" data-id="${esc(item.id)}" aria-label="Kurangi ${actionContext}${esc(item.name)}">−</button>
               <span class="qty-num">${qty}</span>
               <button type="button" class="btn-qty" data-action="inc" data-id="${esc(item.id)}" aria-label="Tambah ${actionContext}${esc(item.name)}">+</button>
           </div>`

    const imageUrl = safeImageUrl(item.image_url)
    card.innerHTML = `
        <div class="menu-info">
            <div class="menu-name">${esc(item.name)}</div>
            ${item.description ? `<div class="menu-desc">${esc(item.description)}</div>` : ''}
            ${promo ? `<div class="menu-promo-badge">${esc(promo.name)}</div>` : ''}
            <div class="menu-price${promo ? ' has-promo' : ''}">
                ${promo ? `<strong>${fmt(promoPrice)}</strong><del>${fmt(item.price)}</del>` : fmt(item.price)}
            </div>
        </div>
        <div class="menu-thumb">
            ${imageUrl
                ? `<img src="${esc(imageUrl)}" alt="${esc(item.name)}" loading="lazy" data-image-fallback="${esc(initials)}">`
                : esc(initials)}
            ${ctrlHtml}
        </div>`
    installImageFallbacks(card)
    return card
}

// ── Cart ───────────────────────────────────────────────────
function addToCart(id) {
    const item = state.menu.find(m => m.id === id)
    if (!item) return
    const itemExtras = state.extrasLookup[id] || []
    if (itemExtras.length > 0) {
        openExtrasModal(item, itemExtras)
        return
    }
    // Item polos boleh digabung selama belum mempunyai catatan khusus. Setelah
    // diberi catatan, penambahan berikutnya menjadi baris baru agar catatan
    // tidak ikut diterapkan ke porsi lain tanpa disengaja.
    const existing = state.cart.find(c =>
        c.id === id
        && (c.selectedExtras || []).length === 0
        && !itemHasNote(c),
    )
    if (existing) {
        if (existing.quantity >= MAX_ITEM_QUANTITY) {
            showToast(`Maksimal ${MAX_ITEM_QUANTITY} porsi per menu`)
            return
        }
        existing.quantity++
    }
    else {
        if (state.cart.length >= MAX_CART_LINES) {
            showToast(`Maksimal ${MAX_CART_LINES} jenis item per pesanan`)
            return
        }
        state.cart.push({
            ...item,
            cartId: createUuid(),
            quantity: 1,
            selectedExtras: [],
            notes: null,
        })
    }
    afterCartChange()
    showToast(`${item.name} ditambahkan`)
}

function decMenuQty(itemId) {
    const matching = state.cart.filter(c => c.id === itemId)
    if (matching.length === 0) return
    const target = matching.find(c =>
        (c.selectedExtras || []).length === 0 && !itemHasNote(c),
    ) || matching[matching.length - 1]
    decQty(target.cartId)
}

function incQty(cartId) {
    const c = state.cart.find(c => c.cartId === cartId)
    if (!c) return
    if (c.quantity >= MAX_ITEM_QUANTITY) {
        showToast(`Maksimal ${MAX_ITEM_QUANTITY} porsi per menu`)
        return
    }
    c.quantity++
    afterCartChange()
}

function decQty(cartId) {
    const idx = state.cart.findIndex(c => c.cartId === cartId)
    if (idx === -1) return
    state.cart[idx].quantity--
    if (state.cart[idx].quantity <= 0) state.cart.splice(idx, 1)
    afterCartChange()
}

// ── Extras Modal ───────────────────────────────────────────
function openExtrasModal(item, extras, editingCartId = null) {
    state._extrasPending  = item
    state._extrasSelections = {}
    state._extrasEditingCartId = editingCartId

    const editingItem = editingCartId
        ? state.cart.find(entry => entry.cartId === editingCartId)
        : null
    for (const selected of editingItem?.selectedExtras || []) {
        if (!state._extrasSelections[selected.menuExtraId]) {
            state._extrasSelections[selected.menuExtraId] = new Set()
        }
        state._extrasSelections[selected.menuExtraId].add(
            selected.menuExtraOptionId,
        )
    }

    el('extrasItemName').textContent = editingItem
        ? `Ubah Pilihan · ${item.name}`
        : `Pilih Tambahan · ${item.name}`
    el('extrasConfirmBtn').textContent = editingItem
        ? 'Simpan Pilihan'
        : 'Tambah ke Pesanan'

    const body = el('extrasBody')
    body.innerHTML = extras.map(extra => {
        const isRequired = extra.type === 'required'
        const isSingle   = extra.selection_type === 'single'
        const options = [...(extra.menu_extra_options || [])].sort((a, b) => a.sort_order - b.sort_order)
        return `
        <div class="extra-group" style="margin-bottom:16px">
            <div style="font-weight:600;font-size:14px;margin-bottom:6px">
                ${esc(extra.name)}
                ${isRequired ? '<span style="color:#10b981;font-size:11px;font-weight:600;background:#d1fae5;border-radius:4px;padding:1px 6px;margin-left:6px">Wajib</span>' : ''}
            </div>
            ${options.map(opt => `
            <label style="display:flex;align-items:center;gap:10px;padding:8px 0;cursor:pointer;border-bottom:1px solid #f3f4f6">
                <input type="${isSingle ? 'radio' : 'checkbox'}"
                    name="extra_${esc(extra.id)}"
                    value="${esc(opt.id)}"
                    data-extra="${esc(extra.id)}"
                    data-option="${esc(opt.id)}"
                    ${state._extrasSelections[extra.id]?.has(opt.id) ? 'checked' : ''}
                    style="accent-color:#10b981;width:16px;height:16px">
                <span style="flex:1;font-size:13px">${esc(opt.name)}</span>
                <span style="font-size:12px;color:${opt.price > 0 ? '#10b981' : '#9ca3af'}">
                    ${opt.price > 0 ? '+' + fmt(opt.price) : 'Gratis'}
                </span>
            </label>`).join('')}
        </div>`
    }).join('')

    // Safari dapat mempertahankan status radio/checkbox dari modal sebelumnya
    // meskipun isi modal sudah dibuat ulang. Paksa properti checked mengikuti
    // state item yang sedang diedit: item baru selalu mulai kosong, sedangkan
    // Ubah Pilihan tetap memuat pilihan milik baris keranjang tersebut.
    for (const input of body.querySelectorAll('input[data-extra][data-option]')) {
        input.checked = state._extrasSelections[input.dataset.extra]
            ?.has(input.dataset.option) === true
    }

    updateExtrasConfirmBtn(extras)
    el('extrasOverlay').classList.remove('hidden')
}

function onExtraChange(input) {
    const extraId    = input.dataset.extra
    const optionId   = input.dataset.option
    const isSingle   = input.type === 'radio'
    const extras = state.extrasLookup[state._extrasPending?.id] || []
    const canonicalExtra = extras.find(extra => extra.id === extraId)
    const canonicalOption = canonicalExtra?.menu_extra_options?.find(
        option => option.id === optionId,
    )
    if (!canonicalExtra || !canonicalOption) {
        input.checked = false
        showToast('Pilihan tambahan sudah tidak tersedia')
        updateExtrasConfirmBtn(extras)
        return
    }
    if (!state._extrasSelections[extraId]) state._extrasSelections[extraId] = new Set()
    if (isSingle) {
        state._extrasSelections[extraId].clear()
        if (input.checked) state._extrasSelections[extraId].add(optionId)
    } else {
        input.checked
            ? state._extrasSelections[extraId].add(optionId)
            : state._extrasSelections[extraId].delete(optionId)
    }
    const selectedCount = Object.values(state._extrasSelections)
        .reduce((total, selection) => total + selection.size, 0)
    if (selectedCount > MAX_OPTIONS_PER_ITEM) {
        state._extrasSelections[extraId].delete(optionId)
        input.checked = false
        showToast(`Maksimal ${MAX_OPTIONS_PER_ITEM} pilihan tambahan per item`)
    }
    updateExtrasConfirmBtn(extras)
}

function getCanonicalExtraOptions(extra) {
    const selected = state._extrasSelections[extra.id] || new Set()
    return (extra.menu_extra_options || []).filter(option => selected.has(option.id))
}

function updateExtrasConfirmBtn(extras) {
    const allRequired = extras
        .filter(e => e.type === 'required')
        .every(e => getCanonicalExtraOptions(e).length > 0)
    el('extrasConfirmBtn').disabled = !allRequired
}

function syncExtrasSelectionsFromInputs(extras) {
    const canonicalOptions = new Map(extras.map(extra => [
        extra.id,
        new Set((extra.menu_extra_options || []).map(option => option.id)),
    ]))
    const selections = {}
    for (const input of el('extrasBody').querySelectorAll(
        'input[data-extra][data-option]:checked',
    )) {
        const extraId = input.dataset.extra
        const optionId = input.dataset.option
        if (!canonicalOptions.get(extraId)?.has(optionId)) continue
        if (!selections[extraId]) selections[extraId] = new Set()
        selections[extraId].add(optionId)
    }
    state._extrasSelections = selections
}

function confirmExtras() {
    const item   = state._extrasPending
    if (!item) return
    const extras = state.extrasLookup[item.id] || []
    // Jadikan kondisi kontrol yang terlihat sebagai sumber terakhir saat
    // konfirmasi. Ini menutup celah bila browser tidak mengirim event `change`
    // tetapi radio/checkbox sudah tampak terpilih.
    syncExtrasSelectionsFromInputs(extras)
    const selectedExtras = []
    for (const extra of extras) {
        const selectedOptions = getCanonicalExtraOptions(extra)
        if (extra.type === 'required' && selectedOptions.length === 0) {
            showToast(`Pilih ${extra.name} terlebih dahulu`)
            return
        }
        if (extra.selection_type === 'single' && selectedOptions.length > 1) {
            showToast(`${extra.name} hanya boleh dipilih satu`)
            return
        }
        for (const opt of selectedOptions) {
            selectedExtras.push({
                menuExtraId:       extra.id,
                menuExtraOptionId: opt.id,
                extraName:         extra.name,
                optionName:        opt.name,
                price:             Number(opt.price) || 0,
            })
        }
    }
    if (selectedExtras.length > MAX_OPTIONS_PER_ITEM) {
        showToast(`Maksimal ${MAX_OPTIONS_PER_ITEM} pilihan tambahan per item`)
        return
    }
    const editingCartId = state._extrasEditingCartId
    if (editingCartId) {
        const editingItem = state.cart.find(entry => entry.cartId === editingCartId)
        if (!editingItem) {
            closeExtrasModal()
            showToast('Item keranjang tidak ditemukan')
            return
        }
        editingItem.selectedExtras = selectedExtras
    } else {
        if (state.cart.length >= MAX_CART_LINES) {
            showToast(`Maksimal ${MAX_CART_LINES} jenis item per pesanan`)
            return
        }
        const cartId = createUuid()
        state.cart.push({ ...item, cartId, quantity: 1, selectedExtras, notes: null })
    }
    closeExtrasModal()
    afterCartChange()
    showToast(editingCartId
        ? `Pilihan ${item.name} diperbarui`
        : `${item.name} ditambahkan`)
}

function closeExtrasModal() {
    el('extrasOverlay').classList.add('hidden')
    state._extrasPending    = null
    state._extrasSelections = {}
    state._extrasEditingCartId = null
    el('extrasConfirmBtn').textContent = 'Tambah ke Pesanan'
}

function openEditExtrasModal(cartId) {
    const item = state.cart.find(entry => entry.cartId === cartId)
    if (!item) return
    const extras = state.extrasLookup[item.id] || []
    if (extras.length === 0) return
    openExtrasModal(item, extras, cartId)
}

// ── Catatan per item ─────────────────────────────────────
function openItemNoteModal(cartId) {
    if (!itemNotesAllowed()) return
    const item = state.cart.find(entry => entry.cartId === cartId)
    if (!item) return
    state._notePendingCartId = cartId
    el('itemNoteMenuName').textContent = `Catatan · ${item.name}`
    el('itemNoteInput').value = normalizeItemNote(item.notes) || ''
    el('itemNoteOverlay').classList.remove('hidden')
    requestAnimationFrame(() => el('itemNoteInput').focus())
}

function closeItemNoteModal() {
    el('itemNoteOverlay').classList.add('hidden')
    state._notePendingCartId = null
}

function saveItemNote() {
    const item = state.cart.find(
        entry => entry.cartId === state._notePendingCartId,
    )
    if (!item) {
        closeItemNoteModal()
        return
    }
    item.notes = normalizeItemNote(el('itemNoteInput').value)
    const message = item.notes ? 'Catatan menu disimpan' : 'Catatan menu dihapus'
    closeItemNoteModal()
    afterCartChange()
    showToast(message)
}

function afterCartChange() {
    clearOrderRequestId()
    invalidateCartAdjustments()
    saveCart()
    updateCartBadge()
    renderMenu()
    renderCartItems()
    updateCartFooter()
    updateFab()
    if (!el('checkoutOverlay').classList.contains('hidden')) {
        _renderCheckoutSummary()
    }
}

function invalidateCartAdjustments() {
    const hadPromo = Boolean(state.promoId || state.voucherId || state.discountAmount)

    state.promoCode = null
    state.promoId = null
    state.voucherId = null
    state.discountAmount = 0
    state.promoName = null

    applyAutomaticProductPromo()

    const promoBtn = el('applyPromoBtn')
    if (promoBtn) promoBtn.textContent = 'Pakai'
    if (hadPromo) {
        const feedback = el('promoFeedback')
        if (feedback) {
            feedback.textContent = 'Keranjang berubah. Terapkan ulang kode promo.'
            feedback.style.color = '#b45309'
        }
    }

}

function applyAutomaticProductPromo() {
    let best = null
    for (const promo of state.productPromos) {
        const eligibleIds = new Set(promo.menu_item_ids || [])
        const eligible = state.cart
            .filter(item => eligibleIds.has(item.id))
            .reduce((sum, item) => {
                const extras = (item.selectedExtras || []).reduce((s, extra) => s + Number(extra.price || 0), 0)
                return sum + (Number(item.price) + extras) * Number(item.quantity || 0)
            }, 0)
        const discount = promoDiscount(promo, eligible)
        if (discount > 0 && (!best || discount > best.discount)) best = { promo, discount }
    }
    if (!best) return
    state.promoId = best.promo.id
    state.promoName = best.promo.name
    state.discountAmount = best.discount
}

function updateCartBadge() {
    const total = cartTotalQty()
    el('cartCount').textContent = total
    el('cartCount').classList.toggle('hidden', total === 0)
}

function updateFab() {
    const qty = cartTotalQty()
    if (qty === 0) { el('cartFab').classList.add('hidden'); return }
    el('cartFab').classList.remove('hidden')
    el('fabCount').textContent = `${qty}`
    el('fabTotal').textContent = fmt(cartSubtotal())
}

// ── Loyalty Member ─────────────────────────────────────────
async function lookupMember() {
    const phone = (el('memberPhoneInput')?.value || '').trim()
    if (!phone) return
    const btn = el('memberLookupBtn')
    const fb  = el('memberFeedback')

    state.memberId = null; state.memberName = null
    state.memberPhone = null; state.memberPoints = 0

    btn.disabled = true; btn.textContent = '...'
    fb.textContent = ''; fb.style.color = '#6b7280'

    try {
        const result = await sb.rpc('find_loyalty_member_by_phone', {
            p_phone:     phone,
            p_outlet_id: state.outlet.id,
            p_table_token: state.tableToken,
        })
        if (result.error) throw new Error(result.error.message)
        const m = result.data
        if (!m) {
            fb.textContent = 'Member tidak ditemukan'
            fb.style.color = '#ef4444'
            btn.textContent = 'Cari'
            return
        }
        state.memberId     = m.id
        state.memberName   = m.name || '-'
        state.memberPhone  = m.phone
        state.memberPoints = m.points || 0

        fb.textContent = `✓ ${state.memberName} • ${state.memberPoints} poin tersedia`
        fb.style.color  = '#10b981'
        btn.textContent = 'Hapus'
        const rb = el('redeemBox')
        if (rb) rb.style.display = ''
    } catch (err) {
        fb.textContent = humanizeError(err, 'Gagal mencari member. Coba lagi sebentar.')
        fb.style.color = '#ef4444'
        btn.textContent = 'Cari'
    } finally {
        btn.disabled = false
    }
}

function removeMember() {
    clearOrderRequestId()
    state.memberId = null; state.memberName = null
    state.memberPhone = null; state.memberPoints = 0
    state.redeemPoints = 0; state.redeemDiscount = 0
    const inp = el('memberPhoneInput')
    if (inp) inp.value = ''
    const fb  = el('memberFeedback')
    if (fb) { fb.textContent = ''; fb.style.color = '' }
    const btn = el('memberLookupBtn')
    if (btn) btn.textContent = 'Cari'
    const rb = el('redeemBox')
    if (rb) rb.style.display = 'none'
    const ri = el('redeemInput')
    if (ri) ri.value = ''
    const rfb = el('redeemFeedback')
    if (rfb) { rfb.textContent = ''; rfb.style.color = '' }
    const rbt = el('redeemBtn')
    if (rbt) rbt.textContent = 'Tukar'
}

async function applyRedeem() {
    const pts = parseInt(el('redeemInput')?.value || '0', 10)
    if (!pts || pts <= 0) return
    if (!state.memberId) return
    const btn = el('redeemBtn')
    const fb  = el('redeemFeedback')
    state.redeemPoints = 0; state.redeemDiscount = 0

    btn.disabled = true; btn.textContent = '...'
    fb.textContent = ''; fb.style.color = '#6b7280'

    try {
        const result = await sb.rpc('validate_loyalty_redeem', {
            p_member_id:      state.memberId,
            p_points:         pts,
            p_subtotal:       cartSubtotal(),
            p_promo_discount: state.discountAmount || 0,
        })
        if (result.error) throw new Error(result.error.message)
        const d = result.data
        state.redeemPoints   = d.points_used
        state.redeemDiscount = d.discount_amount
        clearOrderRequestId()

        fb.textContent = `✓ ${d.points_used} poin → diskon ${fmt(d.discount_amount)}`
        fb.style.color  = '#10b981'
        btn.textContent = 'Batal'
    } catch (err) {
        fb.textContent = humanizeError(err, 'Gagal menukar poin. Coba lagi sebentar.')
        fb.style.color = '#ef4444'
        btn.textContent = 'Tukar'
    } finally {
        btn.disabled = false
    }

    if (!el('checkoutOverlay').classList.contains('hidden')) {
        _renderCheckoutSummary()
    }
}

function removeRedeem() {
    clearOrderRequestId()
    state.redeemPoints = 0; state.redeemDiscount = 0
    const inp = el('redeemInput')
    if (inp) inp.value = ''
    const fb  = el('redeemFeedback')
    if (fb) { fb.textContent = ''; fb.style.color = '' }
    const btn = el('redeemBtn')
    if (btn) btn.textContent = 'Tukar'
    if (!el('checkoutOverlay').classList.contains('hidden')) {
        _renderCheckoutSummary()
    }
}

// ── Promo / Voucher ────────────────────────────────────────
async function applyPromoCode() {
    const code = (el('promoCodeInput')?.value || '').trim()
    if (!code) return

    const btn = el('applyPromoBtn')
    const fb  = el('promoFeedback')

    // Reset promo state first
    state.promoCode = null; state.promoId = null
    state.voucherId = null; state.discountAmount = 0; state.promoName = null

    btn.disabled = true
    btn.textContent = '...'
    fb.textContent = ''
    fb.style.color = '#6b7280'

    try {
        const result = await sb.rpc('validate_promo_code', {
            p_code:       code,
            p_outlet_id:  state.outlet.id,
            p_subtotal:   cartSubtotal(),
        })
        if (result.error) throw new Error(result.error.message)
        const d = result.data
        state.promoCode      = code
        state.promoId        = d.promo_id
        state.voucherId      = d.voucher_id
        state.discountAmount = d.discount_amount
        state.promoName      = d.promo_name
        clearOrderRequestId()

        fb.textContent = `✓ Hemat ${fmt(d.discount_amount)} — ${d.promo_name || 'Promo'}`
        fb.style.color  = '#10b981'
        btn.textContent = 'Hapus'
    } catch (err) {
        applyAutomaticProductPromo()
        const msg = humanizeError(err, 'Kode voucher tidak valid atau tidak dapat digunakan.')
        fb.textContent = msg
        fb.style.color  = '#ef4444'
        btn.textContent = 'Pakai'
    } finally {
        btn.disabled = false
    }

    // Refresh checkout summary if checkout is already open
    if (!el('checkoutOverlay').classList.contains('hidden')) {
        _renderCheckoutSummary()
    }
}

function removePromoCode() {
    clearOrderRequestId()
    state.promoCode = null; state.promoId = null
    state.voucherId = null; state.discountAmount = 0; state.promoName = null
    applyAutomaticProductPromo()
    const inp = el('promoCodeInput')
    if (inp) inp.value = ''
    const fb  = el('promoFeedback')
    if (fb)  { fb.textContent = ''; fb.style.color = '' }
    const btn = el('applyPromoBtn')
    if (btn) btn.textContent = 'Pakai'
    if (!el('checkoutOverlay').classList.contains('hidden')) {
        _renderCheckoutSummary()
    }
}

function _renderCheckoutSummary() {
    const discount  = state.discountAmount || 0
    const { sub, tax, svc, taxPct, svcPct, total } =
        computeCartTotals({ discount })

    const serviceLabel = state.orderMode === 'pickup'
        ? 'Bawa Pulang · Ambil di kasir'
        : `Makan di Tempat · Meja ${state.table?.table_number || '—'}`
    el('checkoutItems').innerHTML = `<div class="summary-item checkout-service">
        <span>Jenis layanan</span><strong>${esc(serviceLabel)}</strong>
    </div>` + state.cart.map(i => {
        const extrasPrice = (i.selectedExtras || []).reduce((s, e) => s + e.price, 0)
        const unitPrice   = i.price + extrasPrice
        const extrasLabel = (i.selectedExtras || []).length > 0
            ? `<div style="font-size:11px;color:#6b7280">${i.selectedExtras.map(e => esc(e.optionName)).join(', ')}</div>`
            : ''
        const noteLabel = itemHasNote(i)
            ? `<div class="summary-item-note">Catatan: ${esc(normalizeItemNote(i.notes))}</div>`
            : ''
        return `<div class="summary-item">
            <span>${esc(i.name)} × ${i.quantity}${extrasLabel}${noteLabel}</span>
            <span>${fmt(unitPrice * i.quantity)}</span>
         </div>`
    }).join('')

    if (discount > 0) {
        el('checkoutItems').innerHTML +=
            `<div class="summary-item" style="color:#10b981">
                <span>Diskon (${esc(state.promoCode || state.promoName || 'Promo produk')})</span>
                <span>- ${fmt(discount)}</span>
             </div>`
    }

    el('checkoutTotal').textContent = fmt(total)
}

// ── Cart modal ─────────────────────────────────────────────
function openCart() {
    renderCartItems()
    updateCartFooter()
    el('cartNotes').value = el('orderNotes').value
    el('cartOverlay').classList.remove('hidden')
}

function renderCartItems() {
    const body = el('cartItems')
    if (state.cart.length === 0) {
        body.innerHTML = '<p class="empty-msg">Keranjang kosong</p>'
        el('checkoutBtn').disabled = true
        return
    }
    el('checkoutBtn').disabled = false
    body.innerHTML = state.cart.map(item => {
        const extrasTotal = (item.selectedExtras || []).reduce((s, e) => s + e.price, 0)
        const unitPrice   = item.price + extrasTotal
        const extrasHtml  = (item.selectedExtras || []).length > 0
            ? `<div style="font-size:11px;color:#6b7280;margin-top:2px">${item.selectedExtras.map(e => esc(e.optionName)).join(', ')}</div>`
            : ''
        const note = normalizeItemNote(item.notes)
        const noteHtml = note
            ? `<div class="cart-item-note">Catatan: ${esc(note)}</div>`
            : ''
        const noteButton = itemNotesAllowed()
            ? `<button type="button" class="btn-item-note" data-action="note" data-cart-id="${esc(item.cartId)}" aria-label="${note ? 'Ubah' : 'Tambah'} catatan untuk ${esc(item.name)}">${note ? 'Ubah catatan' : '+ Tambah catatan'}</button>`
            : ''
        const extrasButton = (state.extrasLookup[item.id] || []).length > 0
            ? `<button type="button" class="btn-item-option" data-action="extras" data-cart-id="${esc(item.cartId)}" aria-label="Ubah pilihan tambahan untuk ${esc(item.name)}">Ubah pilihan</button>`
            : ''
        const editActions = noteButton || extrasButton
            ? `<div class="cart-item-actions">${extrasButton}${noteButton}</div>`
            : ''
        const imageUrl = safeImageUrl(item.image_url)
        return `
        <div class="cart-item">
            <div class="cart-thumb">
                ${imageUrl
                    ? `<img src="${esc(imageUrl)}" alt="${esc(item.name)}" data-image-fallback="${esc(item.name.substring(0,2).toUpperCase())}">`
                    : esc(item.name.substring(0,2).toUpperCase())}
            </div>
            <div class="cart-info">
                <div class="cart-name">${esc(item.name)}</div>
                ${extrasHtml}
                ${noteHtml}
                <div class="cart-price">${fmt(unitPrice)}</div>
                ${editActions}
            </div>
            <div class="cart-ctrl">
                <button type="button" class="btn-qty" data-action="dec" data-cart-id="${esc(item.cartId)}" aria-label="Kurangi ${esc(item.name)}">−</button>
                <span class="qty-num">${item.quantity}</span>
                <button type="button" class="btn-qty" data-action="inc" data-cart-id="${esc(item.cartId)}" aria-label="Tambah ${esc(item.name)}">+</button>
            </div>
        </div>`
    }).join('')
    installImageFallbacks(body)
}

function updateCartFooter() {
    const { sub, tax, svc, svcPct, taxName, taxInclusive, total } = computeCartTotals()

    el('cartSubtotal').textContent = fmt(sub)

    const taxRow = el('taxRow')
    if (tax > 0) {
        taxRow.style.display = ''
        // Saat harga sudah memuat pajak, pajaknya BUKAN tambahan — jangan
        // tampilkan seolah menambah total, cukup sebutkan sudah termasuk.
        el('taxLabel').textContent = taxInclusive ? `Termasuk ${taxName}` : taxName
        el('cartTax').textContent  = fmt(tax)
    } else { taxRow.style.display = 'none' }

    const svcRow = el('serviceRow')
    if (svc > 0) {
        svcRow.style.display = ''
        el('serviceLabel').textContent = `Service ${svcPct}%`
        el('cartService').textContent  = fmt(svc)
    } else { svcRow.style.display = 'none' }

    el('cartTotal').textContent = fmt(total)
}

// ── Checkout ───────────────────────────────────────────────
function openCheckout() {
    if (!state.orderMode) {
        showToast('Pilih jenis layanan terlebih dahulu.')
        showWelcome()
        return
    }
    el('customerName').value = state.customerName
    el('cartOverlay').classList.add('hidden')
    _renderCheckoutSummary()
    el('checkoutOverlay').classList.remove('hidden')
}

async function submitOrder() {
    const btn = el('submitBtn')
    if (btn.disabled || !state.outlet || !state.table || !state.tableToken) return
    if (state.cart.length === 0) {
        showToast('Keranjang masih kosong.')
        return
    }
    if (!state.orderMode || !ORDER_MODES[state.orderMode]) {
        showToast('Pilih jenis layanan terlebih dahulu.')
        showWelcome()
        return
    }
    const customerName = requireCustomerName('customerName')
    if (!customerName) return
    btn.disabled = true
    btn.textContent = 'Mengirim...'

    try {
        const notes        = itemNotesAllowed()
            ? el('orderNotes').value.trim() || null
            : null
        const serviceNotes = buildServiceNotes(notes)

        // Satu RPC atomik: order + items + options dalam satu transaksi.
        // Sebelumnya 3 insert terpisah → putus koneksi di tengah bisa
        // meninggalkan order tanpa item / item tanpa opsi.
        const items = state.cart.map(i => {
            const extrasPrice = (i.selectedExtras || []).reduce((s, e) => s + e.price, 0)
            const unitPrice   = i.price + extrasPrice
            return {
                menu_item_id: i.id,
                quantity:     i.quantity,
                unit_price:   unitPrice,
                subtotal:     unitPrice * i.quantity,
                notes:        itemNotesAllowed() ? normalizeItemNote(i.notes) : null,
                options: (i.selectedExtras || []).map(extra => ({
                    menu_extra_id:        extra.menuExtraId,
                    menu_extra_option_id: extra.menuExtraOptionId,
                    extra_name:           extra.extraName,
                    option_name:          extra.optionName,
                    price:                extra.price,
                })),
            }
        })

        // Total dan diskon dihitung server. Klien hanya mengirim kode promo dan
        // nomor HP member earning-only, bukan nominal diskon atau UUID member.
        const requestId = getOrCreateOrderRequestId()
        const orderArgs = {
            p_outlet_id:     state.outlet.id,
            p_table_id:      state.table.id,
            p_items:         items,
            p_table_token:   state.tableToken,
            p_customer_name: customerName,
            p_notes:         serviceNotes,
            p_promo_code:    state.promoCode || null,
            p_member_phone:  state.memberPhone || null,
            p_request_id:    requestId,
            p_product_promo_id: state.promoCode ? null : state.promoId,
        }
        let result = await sb.rpc('create_self_order', orderArgs)

        // Kompatibilitas untuk checkout TANPA member saat migration baru belum
        // diterapkan. Nomor member tidak boleh dibuang diam-diam; bila diisi,
        // pelanggan diminta mencoba lagi setelah backend siap.
        if (isMissingIdempotencyRpc(result.error)) {
            const { p_product_promo_id: _, ...memberPhoneArgs } = orderArgs
            result = await sb.rpc('create_self_order', memberPhoneArgs)
        }
        if (isMissingIdempotencyRpc(result.error)) {
            const { p_member_phone: _, p_product_promo_id: __, ...baseArgs } = orderArgs
            const idempotentLegacyArgs = {
                ...baseArgs,
                p_member_id: null,
                p_redeem_points: 0,
            }
            result = await sb.rpc('create_self_order', idempotentLegacyArgs)
            if (isMissingIdempotencyRpc(result.error)) {
                const { p_request_id: ___, ...legacyArgs } = idempotentLegacyArgs
                result = await sb.rpc('create_self_order', legacyArgs)
            }
        }
        const { data: created, error: orderErr } = result
        if (orderErr) throw orderErr
        if (!created?.order_id || !created?.order_number) {
            throw new Error('Respons pesanan tidak lengkap')
        }
        const orderId     = created.order_id
        const orderNumber = created.order_number
        // Token riwayat berbeda dari ID order. ID database bukan kredensial.
        rememberOrder(orderId, created.access_token)
        clearOrderRequestId()

        // Server mencocokkan nomor HP tanpa membuka UUID/nama/saldo member ke
        // browser anonim. Order yang cocok akan mendapat poin setelah dibayar;
        // redeem tetap hanya tersedia melalui kasir terautentikasi.

        // Success
        el('checkoutOverlay').classList.add('hidden')
        el('successNum').textContent = orderNumber
        el('successDesc').textContent = state.orderMode === 'pickup'
            ? 'Pesanan diteruskan ke kasir. Silakan ambil setelah pesanan siap.'
            : `Pesanan diteruskan ke kasir untuk Meja ${state.table.table_number}.`
        el('successOverlay').classList.remove('hidden')

        // Reset promo state
        state.promoCode = null; state.promoId = null
        state.voucherId = null; state.discountAmount = 0; state.promoName = null
        const promoInp = el('promoCodeInput')
        if (promoInp) promoInp.value = ''
        const promoFb = el('promoFeedback')
        if (promoFb) { promoFb.textContent = ''; promoFb.style.color = '' }
        const promoBtn = el('applyPromoBtn')
        if (promoBtn) promoBtn.textContent = 'Pakai'

        // Clear cart
        state.cart = []
        saveCart()
        updateCartBadge()
        updateFab()
        renderMenu()

    } catch (err) {
        showToast('❌ ' + humanizeError(err, 'Gagal mengirim pesanan. Coba lagi sebentar.'))
    } finally {
        btn.disabled = false
        btn.textContent = 'Kirim Pesanan'
    }
}

// ── Helpers ───────────────────────────────────────────────

/**
 * Hitung pajak, service, & total keranjang — CERMIN create_self_order di server
 * (migration 114), termasuk Math.round()-nya.
 *
 * Server yang berwenang atas total; layar ini hanya boleh mengutip angka yang
 * sama. Kalau berbeda, pelanggan melihat satu harga tapi ordernya tersimpan
 * dengan harga lain.
 *
 * Dulu rumus ini disalin di TIGA tempat di berkas ini dan ketiganya mengabaikan
 * `tax_inclusive` — jadi begitu setelan "harga sudah termasuk pajak" dinyalakan,
 * pelanggan dikutip pajak dobel sementara server tidak menambahkannya. Satu
 * rumus, satu tempat, supaya tidak melenceng lagi.
 */
function computeCartTotals({ discount = 0, redeem = 0 } = {}) {
    const settings = state.outlet?.settings || {}
    const svcPct   = settings.service_charge_percent || 0
    const sub      = cartSubtotal()

    // Pajak MULTI-ATURAN — CERMIN trigger server enforce_self_order_tax_policy
    // (131) & tax_calculator mobile. Dukung settings.taxes[]; fallback ke field
    // tunggal legacy (tax_percent) bila array belum ada. order_type di menu ini
    // SELALU self_order. Dulu web hanya membaca tax_percent tunggal → untuk
    // outlet ber-banyak-aturan, quote web ≠ total yang server simpan/tagih.
    const baseAfter = Math.max(sub - discount - redeem, 0)
    const rules = (Array.isArray(settings.taxes) && settings.taxes.length)
        ? settings.taxes
        : [{
            percent:     settings.tax_active !== false ? (settings.tax_percent || 0) : 0,
            active:      settings.tax_active !== false,
            inclusive:   settings.tax_inclusive === true,
            calculation: settings.tax_calculation || 'before_discount',
            order_types: settings.tax_order_types,
          }]

    let tax = 0, hasIncl = false, hasExcl = false
    for (const r of rules) {
        const pct = Number(r.percent) || 0
        let active = r.active !== false
        const ots = r.order_types
        if (Array.isArray(ots) && ots.length && !ots.includes('self_order')) active = false
        if (!active || pct <= 0) continue
        const base = (r.calculation === 'after_discount') ? baseAfter : sub
        tax += (r.inclusive === true)
            ? Math.round(base - base / (1 + pct / 100))
            : Math.round(base * pct / 100)
        if (r.inclusive === true) hasIncl = true; else hasExcl = true
    }
    const incl = hasIncl && !hasExcl   // mode campuran → diperlakukan exclusive
    const svc  = Math.round(sub * svcPct / 100)

    // Total + PEMBULATAN (snapshot server 131). rounding hanya 100/500/1000.
    const rawTotal = Math.max(0, sub - discount - redeem) + (incl ? 0 : tax) + svc
    const rounding = [100, 500, 1000].includes(Number(settings.rounding)) ? Number(settings.rounding) : 0
    const total = rounding > 0 ? Math.round(rawTotal / rounding) * rounding : rawTotal

    // taxPct hanya untuk label ringkas (Σ persen aturan aktif yg berlaku).
    const taxPct = rules.reduce((s, r) => {
        const p = Number(r.percent) || 0
        let a = r.active !== false
        const ots = r.order_types
        if (Array.isArray(ots) && ots.length && !ots.includes('self_order')) a = false
        return (a && p > 0) ? s + p : s
    }, 0)

    return {
        sub, tax, svc, taxPct, svcPct,
        taxName: settings.tax_name || `Pajak ${taxPct}%`,
        taxInclusive: incl,
        total,
    }
}

function cartTotalQty() { return state.cart.reduce((s, c) => s + c.quantity, 0) }
function cartSubtotal()  {
    return state.cart.reduce((s, c) => {
        const extrasPrice = (c.selectedExtras || []).reduce((es, e) => es + e.price, 0)
        return s + (c.price + extrasPrice) * c.quantity
    }, 0)
}
function el(id)          { return document.getElementById(id) }
function esc(s)          { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])) }
function safeImageUrl(value) {
    if (!value) return null
    try {
        const url = new URL(String(value), window.location.origin)
        return url.origin === window.location.origin || url.protocol === 'https:'
            ? url.href
            : null
    } catch { return null }
}
function installImageFallbacks(root) {
    root.querySelectorAll('img[data-image-fallback]').forEach(image => {
        image.addEventListener('error', () => {
            const fallback = image.dataset.imageFallback || ''
            image.parentElement.textContent = fallback
        }, { once: true })
    })
}
function createUuid() {
    if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()

    // Android WebView lama belum selalu menyediakan randomUUID. Gunakan
    // generator UUID v4 berbasis crypto agar keranjang dan percobaan ulang
    // order tetap memiliki identitas yang stabil.
    const bytes = new Uint8Array(16)
    crypto.getRandomValues(bytes)
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    const hex = [...bytes].map(byte => byte.toString(16).padStart(2, '0'))
    return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10).join('')}`
}
function pendingRequestKey() {
    return `t420_pending_order_${state.outlet?.id || ''}_${state.table?.id || ''}_${state.orderMode || 'unselected'}`
}
function getOrCreateOrderRequestId() {
    if (state.orderRequestId) return state.orderRequestId
    try {
        const stored = sessionStorage.getItem(pendingRequestKey())
        if (stored && /^[0-9a-f-]{36}$/i.test(stored)) {
            state.orderRequestId = stored
            return stored
        }
    } catch { /* penyimpanan sesi boleh tidak tersedia */ }

    state.orderRequestId = createUuid()
    try { sessionStorage.setItem(pendingRequestKey(), state.orderRequestId) }
    catch { /* tetap aman selama halaman tidak dimuat ulang */ }
    return state.orderRequestId
}
function clearOrderRequestId() {
    state.orderRequestId = null
    try { sessionStorage.removeItem(pendingRequestKey()) }
    catch { /* tidak memengaruhi keberhasilan order */ }
}
function isMissingIdempotencyRpc(error) {
    if (!error) return false
    const text = `${error.code || ''} ${error.message || ''} ${error.details || ''}`.toLowerCase()
    return error.code === 'PGRST202'
        || (text.includes('create_self_order') && text.includes('p_request_id'))
        || text.includes('could not find the function')
}
function fmt(n)          { return new Intl.NumberFormat('id-ID', { style:'currency', currency:'IDR', minimumFractionDigits:0 }).format(n) }

// Ubah error teknis (Postgres/Supabase/jaringan) jadi pesan ramah untuk
// pelanggan. Error mentah tetap dicatat ke console untuk debugging.
function humanizeError(err, fallback) {
    if (err) console.error('[error]', err)
    const code = err && err.code
    const text = `${(err && err.message) || ''} ${(err && err.details) || ''} ${(err && err.hint) || ''}`.toLowerCase()
    if (text.includes('row-level security') || text.includes('permission') || text.includes('not authorized') || code === '42501')
        return 'Pesanan belum bisa diproses. Silakan panggil kasir.'
    if (code === '23505' || text.includes('duplicate'))
        return 'Pesanan sepertinya sudah terkirim. Konfirmasi ke kasir.'
    if (code === '23503' || text.includes('foreign key'))
        return 'Menu atau meja tidak valid. Coba scan ulang QR code.'
    if (code === '23502')
        return 'Ada data pesanan yang belum lengkap.'
    if (text.includes('jwt') || text.includes('expired') || text.includes('session'))
        return 'Sesi berakhir. Muat ulang halaman lalu coba lagi.'
    if (text.includes('network') || text.includes('failed to fetch') || text.includes('fetch') || text.includes('timeout') || text.includes('load failed'))
        return 'Koneksi bermasalah. Periksa internet Anda lalu coba lagi.'
    return fallback || 'Terjadi kesalahan. Coba lagi sebentar.'
}

function showToast(msg) {
    const t = el('toast')
    t.textContent = msg
    t.classList.remove('hidden')
    t.classList.add('show')
    setTimeout(() => { t.classList.remove('show'); setTimeout(() => t.classList.add('hidden'), 300) }, 2500)
}

function orderModeLabel(mode = state.orderMode) {
    return ORDER_MODES[mode]?.label || 'Pilih jenis layanan'
}

function setCustomerName(value) {
    state.customerName = String(value || '').slice(0, 80)
    for (const id of ['initialCustomerName', 'customerName']) {
        const input = el(id)
        if (input.value !== state.customerName) input.value = state.customerName
        if (state.customerName.trim()) input.removeAttribute('aria-invalid')
    }
    if (state.customerName.trim()) el('initialNameError').textContent = ''
    clearOrderRequestId()
}

function openInitialName() {
    el('initialCustomerName').value = state.customerName
    el('initialNameOverlay').classList.remove('hidden')
    requestAnimationFrame(() => el('initialCustomerName').focus())
}

function closeInitialName() {
    el('initialNameOverlay').classList.add('hidden')
}

function requireCustomerName(focusId = 'initialCustomerName') {
    const customerName = state.customerName.trim()
    if (customerName) {
        if (customerName !== state.customerName) setCustomerName(customerName)
        return customerName
    }

    el('initialNameError').textContent = 'Nama pemesan wajib diisi.'
    showToast('Nama pemesan wajib diisi.')
    if (focusId === 'initialCustomerName') openInitialName()
    const input = el(focusId)
    input.focus()
    input.setAttribute('aria-invalid', 'true')
    return null
}

function buildServiceNotes(userNotes) {
    const service = state.orderMode === 'pickup'
        ? 'Jenis layanan: Bawa Pulang'
        : `Jenis layanan: Makan di Tempat (Meja ${state.table?.table_number || '—'})`
    const payment = state.paymentMethod === 'qris'
        ? 'Cara bayar: QRIS (menunggu verifikasi petugas)'
        : 'Cara bayar: Bayar di kasir'
    return userNotes ? `${service}\n${payment}\n${userNotes}` : `${service}\n${payment}`
}

function selectPaymentMethod(value) {
    state.paymentMethod = value === 'pay_at_cashier' ? 'pay_at_cashier' : 'qris'
    for (const option of document.querySelectorAll('.payment-option')) {
        const input = option.querySelector('input[name="customerPaymentMethod"]')
        const selected = input?.value === state.paymentMethod
        if (input) input.checked = selected
        option.classList.toggle('selected', selected)
    }
    clearOrderRequestId()
}

function renderWelcome() {
    if (!state.outlet || !state.table) return
    const outletName = state.outlet.name || 'QR Ordering'
    const tableLabel = state.table.area
        ? `${state.table.area} · Meja ${state.table.table_number}`
        : `Meja ${state.table.table_number}`
    el('welcomeTitle').textContent = outletName
    el('welcomeOutletName').textContent = outletName
    el('welcomeTableLabel').textContent = tableLabel
    el('dineInTableLabel').textContent = `Pesan dari Meja ${state.table.table_number}`

    const logoUrl = safeImageUrl(state.outlet.logo_url) || 'logo.png'
    el('welcomeLogo').src = logoUrl
    el('welcomeLogo').alt = `Logo ${outletName}`
    el('welcomeOutletImage').src = logoUrl
    el('welcomeOutletImage').alt = `Logo ${outletName}`

    const settings = state.outlet.settings || {}
    const firstMenuImage = state.menu.map(item => safeImageUrl(item.image_url)).find(Boolean)
    const heroUrl = safeImageUrl(settings.customer_menu_cover_url)
        || firstMenuImage
    const hero = el('welcomeHeroImage')
    const heroFrame = hero.closest('.welcome-hero')
    const heroBackdrop = el('welcomeHeroBackdrop')
    const fallbackHeroUrl = firstMenuImage && firstMenuImage !== heroUrl
        ? firstMenuImage
        : null
    hero.onload = () => {
        if (hero.naturalWidth > 0 && hero.naturalHeight > 0) {
            heroFrame.style.setProperty(
                '--welcome-hero-aspect',
                `${hero.naturalWidth} / ${hero.naturalHeight}`,
            )
            heroFrame.classList.add('has-fitted-image')
        }
        hero.classList.remove('hidden')
        heroBackdrop.src = hero.currentSrc || hero.src
        heroBackdrop.classList.remove('hidden')
    }
    hero.onerror = () => {
        if (fallbackHeroUrl && hero.getAttribute('src') !== fallbackHeroUrl) {
            hero.src = fallbackHeroUrl
            return
        }
        hero.removeAttribute('src')
        hero.alt = ''
        hero.classList.add('hidden')
        heroBackdrop.removeAttribute('src')
        heroBackdrop.classList.add('hidden')
        heroFrame.classList.remove('has-fitted-image')
        heroFrame.style.removeProperty('--welcome-hero-aspect')
    }
    if (heroUrl) {
        hero.src = heroUrl
        hero.alt = `Suasana ${outletName}`
        hero.classList.remove('hidden')
    } else {
        hero.removeAttribute('src')
        hero.alt = ''
        hero.classList.add('hidden')
        heroBackdrop.removeAttribute('src')
        heroBackdrop.classList.add('hidden')
        heroFrame.classList.remove('has-fitted-image')
        heroFrame.style.removeProperty('--welcome-hero-aspect')
    }
}

function updateServiceUi() {
    if (!state.table) return
    const badge = el('tableBadge')
    badge.textContent = state.orderMode === 'pickup'
        ? 'Bawa Pulang'
        : `Meja ${state.table.table_number}`
    el('cartTableBadge').textContent = badge.textContent
    for (const [mode, buttonId] of [['dine_in', 'dineInBtn'], ['pickup', 'pickupBtn']]) {
        const button = el(buttonId)
        const selected = state.orderMode === mode
        button.classList.toggle('selected', selected)
        button.setAttribute('aria-pressed', String(selected))
    }
}

function hidePrimaryScreens() {
    for (const id of ['scanScreen', 'errorScreen', 'welcomeScreen', 'app']) {
        el(id).classList.add('hidden')
    }
}

function showScanScreen() {
    el('loadingScreen').classList.add('hidden')
    hidePrimaryScreens()
    el('scanScreen').classList.remove('hidden')
}
function showError(msg) {
    el('loadingScreen').classList.add('hidden')
    hidePrimaryScreens()
    el('errorMsg').textContent = msg
    el('errorScreen').classList.remove('hidden')
}
function revealApp() {
    el('loadingScreen').classList.add('hidden')
    el('welcomeScreen').classList.add('hidden')
    el('app').classList.remove('hidden')
}
function closeCustomerOverlays() {
    for (const id of ['cartOverlay', 'checkoutOverlay', 'historyOverlay', 'extrasOverlay', 'itemNoteOverlay']) {
        el(id).classList.add('hidden')
    }
}
function showWelcome({ afterSplash = false } = {}) {
    const reveal = () => {
        closeCustomerOverlays()
        hidePrimaryScreens()
        updateServiceUi()
        el('welcomeScreen').classList.remove('hidden')
        if (!state.customerName.trim()) openInitialName()
    }
    if (afterSplash) {
        el('loadingScreen').classList.add('fade-out')
        setTimeout(() => {
            el('loadingScreen').classList.add('hidden')
            reveal()
        }, 400)
    } else {
        el('loadingScreen').classList.add('hidden')
        reveal()
    }
}

function selectOrderMode(mode) {
    if (!ORDER_MODES[mode]) return
    if (!requireCustomerName()) return
    if (state.orderMode !== mode) {
        clearOrderRequestId()
        state.orderMode = mode
        removePromoCode()
        loadCart()
    }
    updateServiceUi()
    updateCartBadge()
    renderMenu()
    renderCartItems()
    updateCartFooter()
    updateFab()
    closeInitialName()
    revealApp()
}

// ── Persist cart ───────────────────────────────────────────
function saveCart()  {
    if (!state.orderMode) return
    try {
        localStorage.setItem(cartStorageKey(), JSON.stringify(state.cart))
    } catch {
        // Mode privat atau penyimpanan penuh tidak boleh menghentikan pemesanan.
    }
}
function loadCart()  {
    let raw = null
    let migratedLegacy = false
    try {
        raw = localStorage.getItem(cartStorageKey())
        if (!raw && state.orderMode === 'dine_in') {
            raw = localStorage.getItem(legacyCartStorageKey())
            migratedLegacy = Boolean(raw)
        }
    }
    catch { state.cart = []; return }
    if (!raw) { state.cart = []; return }
    if (raw) try {
        const parsed = JSON.parse(raw)
        if (!Array.isArray(parsed)) throw new Error('Format keranjang tidak valid')

        // Penyimpanan browser hanya mengingat pilihan pengguna, bukan menjadi
        // sumber harga. Selaraskan ulang dengan menu terbaru agar item yang
        // dihapus, harga lama, dan opsi lama tidak dibawa ke checkout.
        const usedCartIds = new Set()
        const normalizedCart = []
        for (const stored of parsed) {
            if (normalizedCart.length >= MAX_CART_LINES) break
            const current = state.menu.find(item => item.id === stored?.id)
            if (!current) continue

            const quantity = Math.min(
                Math.max(Number.parseInt(stored.quantity, 10) || 1, 1),
                MAX_ITEM_QUANTITY,
            )
            const storedOptionIds = new Set(
                (Array.isArray(stored.selectedExtras) ? stored.selectedExtras : [])
                    .map(selected => selected?.menuExtraOptionId)
                    .filter(Boolean),
            )
            const selectedExtras = []
            let invalidSelections = false
            for (const extra of state.extrasLookup[current.id] || []) {
                let chosen = (extra.menu_extra_options || [])
                    .filter(option => storedOptionIds.has(option.id))
                if (extra.selection_type === 'single') chosen = chosen.slice(0, 1)
                if (extra.type === 'required' && chosen.length === 0) {
                    invalidSelections = true
                    break
                }
                for (const option of chosen) {
                    if (selectedExtras.length >= MAX_OPTIONS_PER_ITEM) {
                        invalidSelections = true
                        break
                    }
                    selectedExtras.push({
                        menuExtraId: extra.id,
                        menuExtraOptionId: option.id,
                        extraName: extra.name,
                        optionName: option.name,
                        price: Number(option.price) || 0,
                    })
                }
                if (invalidSelections) break
            }
            if (invalidSelections) continue

            const storedCartId = typeof stored.cartId === 'string'
                ? stored.cartId.trim()
                : ''
            const cartId = storedCartId
                && storedCartId.length <= 128
                && !usedCartIds.has(storedCartId)
                ? storedCartId
                : createUuid()
            usedCartIds.add(cartId)

            normalizedCart.push({
                ...current,
                cartId,
                quantity,
                selectedExtras,
                notes: itemNotesAllowed() ? normalizeItemNote(stored.notes) : null,
            })
        }
        state.cart = normalizedCart
        saveCart()
        if (migratedLegacy) localStorage.removeItem(legacyCartStorageKey())
    } catch { state.cart = [] }
}

function legacyCartStorageKey() {
    return 't420_cart_' + (state.outlet?.id || '')
}
function cartStorageKey() {
    return `t420_cart_${state.outlet?.id || ''}_${state.table?.id || ''}_${state.orderMode || 'unselected'}`
}

// ── Riwayat order ─────────────────────────────────────────
// Simpan pasangan ID + token akses di localStorage (per outlet, cap 20).
// Entri lama yang hanya berisi UUID sengaja tidak digunakan lagi: primary key
// database bukan kapabilitas baca dan tidak boleh membuka rincian pesanan.
function historyKey() { return 't420_orders_' + (state.outlet?.id || '') }
function rememberedOrders() {
    try {
        const a = JSON.parse(localStorage.getItem(historyKey()) || '[]')
        return Array.isArray(a)
            ? a.filter(entry => entry
                && typeof entry === 'object'
                && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(entry.id || '')
                && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(entry.access_token || ''))
                .slice(0, 20)
            : []
    }
    catch { return [] }
}
function rememberOrder(id, accessToken) {
    if (!id || !accessToken) return
    const orders = rememberedOrders().filter(entry => entry.id !== id)
    orders.unshift({ id, access_token: accessToken })
    try { localStorage.setItem(historyKey(), JSON.stringify(orders.slice(0, 20))) }
    catch { return }
    el('historyBtn').classList.remove('hidden')
}

const ORDER_STATUS = {
    draft:     { label: 'Menunggu',   cls: 'st-wait' },
    confirmed: { label: 'Dikonfirmasi', cls: 'st-wait' },
    preparing: { label: 'Diproses',   cls: 'st-prep' },
    ready:     { label: 'Siap',       cls: 'st-ready' },
    served:    { label: 'Disajikan',  cls: 'st-ready' },
    paid:      { label: 'Lunas',      cls: 'st-done' },
    cancelled: { label: 'Dibatalkan', cls: 'st-cancel' },
    void:      { label: 'Dibatalkan', cls: 'st-cancel' },
}

async function openHistory() {
    el('historyOverlay').classList.remove('hidden')
    const body = el('historyBody')
    const ordersWithAccess = rememberedOrders()
    if (ordersWithAccess.length === 0) { body.innerHTML = '<p class="history-empty">Belum ada pesanan.</p>'; return }
    body.innerHTML = '<p class="history-empty">Memuat…</p>'
    const { data, error } = await sb.rpc('get_self_orders', { p_orders: ordersWithAccess })
    if (error) { body.innerHTML = '<p class="history-empty">Gagal memuat riwayat. Coba lagi.</p>'; console.error('[riwayat]', error); return }
    const orders = Array.isArray(data) ? data : []
    if (orders.length === 0) { body.innerHTML = '<p class="history-empty">Belum ada pesanan.</p>'; return }
    body.innerHTML = orders.map(renderHistoryCard).join('')
}

function renderHistoryCard(o) {
    const st = ORDER_STATUS[o.status] || { label: o.status || '—', cls: 'st-wait' }
    const items = Array.isArray(o.items) ? o.items : []
    const itemLine = items.map(it => `${esc(it.name)} ×${it.quantity}`).join(', ')
    let time = ''
    try {
        time = new Date(o.created_at).toLocaleString('id-ID',
            { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })
    } catch { /* ignore */ }
    return `
        <div class="history-card">
            <div class="history-top">
                <span class="history-num">#${esc(o.order_number || '')}</span>
                <span class="history-status ${st.cls}">${esc(st.label)}</span>
            </div>
            <div class="history-items">${itemLine || '—'}</div>
            <div class="history-foot">
                <span class="history-time">${time}</span>
                <span class="history-total">${fmt(o.total_amount || 0)}</span>
            </div>
        </div>`
}

// ── Event wiring ──────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    el('retryBtn').addEventListener('click', () => window.location.reload())

    // Halaman pembuka dan pemilihan jenis layanan.
    el('dineInBtn').addEventListener('click', () => selectOrderMode('dine_in'))
    el('pickupBtn').addEventListener('click', () => selectOrderMode('pickup'))
    el('tableBadge').addEventListener('click', () => showWelcome())

    // Search
    el('searchInput').addEventListener('input', renderMenu)
    el('searchToggleBtn').addEventListener('click', () => toggleMenuSearch())
    el('searchInput').addEventListener('keydown', event => {
        if (event.key === 'Escape') toggleMenuSearch(false)
    })

    // Tombol menu/cart dibuat dari data; satu listener terdelegasi menghindari
    // inline event handler sehingga CSP dapat memblokir script injection.
    el('menuGrid').addEventListener('click', event => {
        const button = event.target.closest('[data-action]')
        if (!button || !button.dataset.id) return
        if (button.dataset.action === 'add') addToCart(button.dataset.id)
        if (button.dataset.action === 'inc') addToCart(button.dataset.id)
        if (button.dataset.action === 'dec') decMenuQty(button.dataset.id)
    })
    el('cartItems').addEventListener('click', event => {
        const button = event.target.closest('[data-action]')
        if (!button || !button.dataset.cartId) return
        if (button.dataset.action === 'inc') incQty(button.dataset.cartId)
        if (button.dataset.action === 'dec') decQty(button.dataset.cartId)
        if (button.dataset.action === 'note') openItemNoteModal(button.dataset.cartId)
        if (button.dataset.action === 'extras') openEditExtrasModal(button.dataset.cartId)
    })

    // Cart open/close
    el('cartBtn').addEventListener('click', openCart)
    el('cartFabBtn').addEventListener('click', openCart)
    el('closeCart').addEventListener('click', () => el('cartOverlay').classList.add('hidden'))
    el('cartOverlay').addEventListener('click', e => { if (e.target === el('cartOverlay')) el('cartOverlay').classList.add('hidden') })

    // Cart → Checkout
    el('checkoutBtn').addEventListener('click', openCheckout)
    el('closeCheckout').addEventListener('click', () => {
        el('checkoutOverlay').classList.add('hidden')
        el('cartOverlay').classList.remove('hidden')
    })
    el('checkoutOverlay').addEventListener('click', e => {
        if (e.target === el('checkoutOverlay')) {
            el('checkoutOverlay').classList.add('hidden')
            el('cartOverlay').classList.remove('hidden')
        }
    })

    // Extras modal close on backdrop click
    el('extrasCloseBtn').addEventListener('click', closeExtrasModal)
    el('extrasConfirmBtn').addEventListener('click', confirmExtras)
    el('extrasBody').addEventListener('change', event => {
        if (event.target instanceof HTMLInputElement) onExtraChange(event.target)
    })
    el('extrasOverlay').addEventListener('click', e => {
        if (e.target === el('extrasOverlay')) closeExtrasModal()
    })

    el('itemNoteCloseBtn').addEventListener('click', closeItemNoteModal)
    el('itemNoteSaveBtn').addEventListener('click', saveItemNote)
    el('itemNoteOverlay').addEventListener('click', event => {
        if (event.target === el('itemNoteOverlay')) closeItemNoteModal()
    })

    // Submit order. Penukaran loyalty sengaja tidak tersedia pada menu anonim;
    // alurnya harus melalui kasir terautentikasi.
    el('applyPromoBtn').addEventListener('click', () => {
        state.promoCode ? removePromoCode() : applyPromoCode()
    })
    el('initialCustomerName').addEventListener('input', event => {
        event.currentTarget.removeAttribute('aria-invalid')
        setCustomerName(event.currentTarget.value)
    })
    el('initialCustomerName').addEventListener('keydown', event => {
        if (event.key === 'Enter') el('saveInitialName').click()
    })
    el('saveInitialName').addEventListener('click', () => {
        if (!requireCustomerName()) return
        closeInitialName()
    })
    el('closeInitialName').addEventListener('click', closeInitialName)
    el('customerName').addEventListener('input', event => {
        event.currentTarget.removeAttribute('aria-invalid')
        setCustomerName(event.currentTarget.value)
    })
    el('orderNotes').addEventListener('input', clearOrderRequestId)
    el('cartNotes').addEventListener('input', event => {
        el('orderNotes').value = event.currentTarget.value
        clearOrderRequestId()
    })
    el('cartPaymentGroup').addEventListener('change', event => {
        if (event.target instanceof HTMLInputElement) {
            selectPaymentMethod(event.target.value)
        }
    })
    el('submitBtn').addEventListener('click', submitOrder)

    // Success done
    el('doneBtn').addEventListener('click', () => {
        el('successOverlay').classList.add('hidden')
        renderMenu()
    })

    // Riwayat pesanan
    el('historyBtn').addEventListener('click', openHistory)
    el('historyClose').addEventListener('click', () => el('historyOverlay').classList.add('hidden'))
    el('historyOverlay').addEventListener('click', e => {
        if (e.target === el('historyOverlay')) el('historyOverlay').classList.add('hidden')
    })

    init()
})

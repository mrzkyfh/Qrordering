const JAKARTA_TIME_ZONE = 'Asia/Jakarta'

// Menghasilkan Date lokal semu yang komponennya selalu mengikuti hari/jam
// operasional Jakarta. Dashboard hanya mengirim komponen tanggal (yyyy-MM-dd),
// jadi ini mencegah browser di zona waktu lain bergeser satu hari.
export function getJakartaNow(reference = new Date()): Date {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: JAKARTA_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(reference)

  const value = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === type)?.value ?? 0)

  return new Date(
    value('year'),
    value('month') - 1,
    value('day'),
    value('hour'),
    value('minute'),
    value('second'),
  )
}

/**
 * Sanitasi input pencarian sebelum dipakai dalam filter string PostgREST `.or()`.
 *
 * Karakter berikut punya makna sintaks di PostgREST dan dapat dipakai untuk
 * memanipulasi struktur filter (menambah kondisi OR, grouping, dst):
 *   ,  pemisah kondisi      ( )  grouping
 *   %  wildcard ilike       *    wildcard
 *   :  pemisah cast/embed    \   escape
 * Semuanya dibuang. Hasil juga di-trim & dibatasi panjangnya.
 */
export function sanitizeSearch(input: string, maxLen = 60): string {
  return input.replace(/[,()%*:\\]/g, '').trim().slice(0, maxLen)
}

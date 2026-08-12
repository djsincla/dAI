/**
 * Whether a node actually has a model, rather than having started to get one.
 *
 * Possession was a key test: the node reports `storedModels` as a map of model
 * id to size, and both the catalogue count and the placement view asked only
 * whether the key was there. A transfer creates its directory and writes into
 * it, so a node one gigabyte into a seventeen gigabyte model reported the key
 * and was counted as holding the whole thing.
 *
 * That is not a cosmetic miscount. `nodesWanting` is derived from the same
 * answer, so it fell to zero the moment the transfer began: the fleet reported
 * distribution complete when one machine had six percent of the weights, and
 * nothing would have said otherwise if the transfer had then failed and stopped
 * at six percent forever.
 *
 * The node reports gibibytes - `bytes / 1073741824` - and the catalogue records
 * bytes, which is why the two numbers never looked comparable by eye: a 17.2 GB
 * model is reported as 16.0.
 */
const GIB = 1073741824

/**
 * Slightly under one, because the two sides count different things. The
 * catalogue sums the file sizes it ingested; the node measures what is on its
 * disk, and the answers differ by rounding and by whatever the filesystem says
 * about a directory. A whole percent is far wider than that gap and far
 * narrower than any partial transfer worth catching - the case that prompted
 * this was at six percent.
 */
export const COMPLETE_ENOUGH = 0.99

export function holdsModel(reportedGiB: unknown, catalogueBytes: unknown): boolean {
  const gib = Number(reportedGiB)
  const bytes = Number(catalogueBytes)
  if (!Number.isFinite(gib) || gib <= 0) return false
  // A model whose size the catalogue does not know cannot be checked against
  // anything, so the old rule stands: reporting it at all counts as having it.
  // Refusing here would make every such model look absent everywhere.
  if (!Number.isFinite(bytes) || bytes <= 0) return true
  return gib * GIB >= bytes * COMPLETE_ENOUGH
}

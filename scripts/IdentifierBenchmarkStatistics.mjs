export function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) throw new RangeError("Median requires at least one sample.");
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

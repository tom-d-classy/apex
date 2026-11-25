export function cumulativeMomentum(entries: readonly number[], startingValue = 0): number {
  return entries.reduce((total, value) => total + value, startingValue)
}

export function baseContribution(completion: number): number {
  return completion === 100 ? 1 : (completion - 100) / 100
}

export function delayContribution(hours: number): number {
  return -0.05 * Math.max(0, hours)
}

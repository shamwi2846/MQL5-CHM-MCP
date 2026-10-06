// Validate the already bounded, inflated PNG scanlines without changing source bytes.
// Indexed PNG filter predictors use a one-byte distance, including packed samples.
export function validatePngScanlines(inflated, passes, { bitsPerPixel, bitDepth, colorType, paletteEntries }) {
  let offset = 0;
  for (const [width, height] of passes) {
    const rowBytes = Math.ceil(width * bitsPerPixel / 8);
    let previous = colorType === 3 ? new Uint8Array(rowBytes) : null;
    let current = colorType === 3 ? new Uint8Array(rowBytes) : null;
    for (let row = 0; row < height; row += 1) {
      const filter = inflated[offset];
      if (filter > 4) throw new Error("PNG scanline uses an invalid filter type.");
      if (colorType === 3) {
        for (let column = 0; column < rowBytes; column += 1) {
          const left = column ? current[column - 1] : 0;
          const above = previous[column];
          const upperLeft = column ? previous[column - 1] : 0;
          let predictor = 0;
          if (filter === 1) predictor = left;
          else if (filter === 2) predictor = above;
          else if (filter === 3) predictor = Math.floor((left + above) / 2);
          else if (filter === 4) {
            const value = left + above - upperLeft;
            const a = Math.abs(value - left);
            const b = Math.abs(value - above);
            const c = Math.abs(value - upperLeft);
            predictor = a <= b && a <= c ? left : b <= c ? above : upperLeft;
          }
          current[column] = (inflated[offset + 1 + column] + predictor) & 0xff;
        }
        const mask = (1 << bitDepth) - 1;
        for (let pixel = 0; pixel < width; pixel += 1) {
          const bit = pixel * bitDepth;
          const index = (current[bit >>> 3] >>> (8 - bitDepth - (bit & 7))) & mask;
          if (index >= paletteEntries) throw new Error("PNG pixel index is outside its palette.");
        }
        [previous, current] = [current, previous];
      }
      offset += rowBytes + 1;
    }
  }
}

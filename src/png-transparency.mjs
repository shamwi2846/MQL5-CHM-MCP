// Chunk framing and CRCs are validated by the callers. Keep transparency rules
// shared by indexing and delivery, without decoding or changing source bytes.
export function createPngTransparencyValidator() {
  let sawTransparency = false;
  return (type, length, { colorType, paletteEntries, sawPalette, sawData }) => {
    if (type === "PLTE" && sawTransparency) {
      throw new Error("PNG palette follows its transparency chunk.");
    }
    if (type !== "tRNS") return;
    if (sawTransparency || sawData) {
      throw new Error("PNG transparency chunk is duplicated or follows image data.");
    }
    if (colorType === 3) {
      if (!sawPalette || length > paletteEntries) {
        throw new Error("PNG indexed transparency exceeds or precedes its palette.");
      }
    } else if (colorType === 0 || colorType === 2) {
      if (length !== (colorType === 0 ? 2 : 6)) {
        throw new Error("PNG transparency chunk has an invalid sample length.");
      }
    } else {
      throw new Error("PNG transparency chunk is forbidden for this color type.");
    }
    // Short indexed tables, including zero entries, imply opaque remaining
    // palette entries. Sample high bits are not additional rejection criteria.
    sawTransparency = true;
  };
}

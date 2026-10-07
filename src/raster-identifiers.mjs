// Identifier checks must inspect original bytes: Node's ASCII decoder clears
// the high bit and can turn a malformed binary identifier into a valid one.
export function readPngChunkType(bytes) {
  if (bytes.length !== 4 || !bytes.every(byte =>
    (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a))) {
    throw new Error("Invalid PNG chunk type.");
  }
  return bytes.toString("latin1");
}

const GIF87_HEADER = Buffer.from("GIF87a", "ascii");
const GIF89_HEADER = Buffer.from("GIF89a", "ascii");

export function hasGifHeader(bytes) {
  if (bytes.length < 6) return false;
  const header = bytes.subarray(0, 6);
  return header.equals(GIF87_HEADER) || header.equals(GIF89_HEADER);
}

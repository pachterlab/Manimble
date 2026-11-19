// Checks that an uploaded file is a Manimble package without reading all of it: a zip whose central
// directory names exactly one manimble-project.json (as manimbler's _project() requires) and no unsafe paths.
// The full check (every referenced build present) is `manimbler --check`, run by the reviewer.

type ReadRange = (offset: number, length: number) => Promise<Uint8Array>;

const EOCD = 0x06054b50;
const ZIP64_LOCATOR = 0x07064b50;
const ZIP64_EOCD = 0x06064b50;
const CENTRAL_ENTRY = 0x02014b50;
const MAX_CENTRAL_DIRECTORY = 16 * 1024 * 1024;
const MAX_ENTRIES = 100_000;

const notPackage = "This file isn't a Manimble package. Make one with File ▸ Package for Sharing… in Manimble.";

export async function checkPackage(read: ReadRange, size: number): Promise<void> {
  if (size < 22) throw new Error(notPackage);
  const head = await read(0, 4);
  if (head[0] !== 0x50 || head[1] !== 0x4b || head[2] !== 0x03 || head[3] !== 0x04) throw new Error(notPackage);

  // The end-of-central-directory record is in the last 22 bytes plus a comment of up to 64 KB.
  const tailLength = Math.min(size, 22 + 0xffff + 20);
  const tailStart = size - tailLength;
  const tail = await read(tailStart, tailLength);
  const view = new DataView(tail.buffer, tail.byteOffset, tail.byteLength);
  let at = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (view.getUint32(i, true) === EOCD) { at = i; break; }
  }
  if (at < 0) throw new Error(notPackage);
  let entries = view.getUint16(at + 10, true);
  let cdSize = view.getUint32(at + 12, true);
  let cdOffset = view.getUint32(at + 16, true);
  if (entries === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
    if (at < 20 || view.getUint32(at - 20, true) !== ZIP64_LOCATOR) throw new Error(notPackage);
    const recordOffset = Number(view.getBigUint64(at - 20 + 8, true));
    if (recordOffset + 56 > size) throw new Error(notPackage);
    const record = await read(recordOffset, 56);
    const r = new DataView(record.buffer, record.byteOffset, record.byteLength);
    if (r.getUint32(0, true) !== ZIP64_EOCD) throw new Error(notPackage);
    entries = Number(r.getBigUint64(32, true));
    cdSize = Number(r.getBigUint64(40, true));
    cdOffset = Number(r.getBigUint64(48, true));
  }
  if (entries === 0 || entries > MAX_ENTRIES || cdSize > MAX_CENTRAL_DIRECTORY || cdOffset + cdSize > size) {
    throw new Error(notPackage);
  }

  const cd = await read(cdOffset, cdSize);
  const c = new DataView(cd.buffer, cd.byteOffset, cd.byteLength);
  const decoder = new TextDecoder();
  const names: string[] = [];
  for (let p = 0, n = 0; n < entries; n++) {
    if (p + 46 > cd.length || c.getUint32(p, true) !== CENTRAL_ENTRY) throw new Error(notPackage);
    const nameLength = c.getUint16(p + 28, true);
    const extraLength = c.getUint16(p + 30, true);
    const commentLength = c.getUint16(p + 32, true);
    if (p + 46 + nameLength > cd.length) throw new Error(notPackage);
    names.push(decoder.decode(cd.subarray(p + 46, p + 46 + nameLength)));
    p += 46 + nameLength + extraLength + commentLength;
  }
  for (const name of names) {
    const parts = name.replace(/\/$/, "").split("/");
    if (name.startsWith("/") || name.includes("\\") || parts.some((part) => part === "..") || parts[0].includes(":")) {
      throw new Error("The package contains a file with an unsafe path.");
    }
  }
  const manifests = names.filter((n) => n.endsWith("/manimble-project.json") && !n.startsWith("__MACOSX/"));
  if (manifests.length !== 1) throw new Error(notPackage);
}

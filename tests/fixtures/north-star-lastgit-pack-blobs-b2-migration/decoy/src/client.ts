export class NodeClient {
  /*
  this.req("POST", "/api/db/file-blob"
  key: { hash: contentHash, range: null }
  data: ""
  bytes_b64: plaintext.toString("base64")
  cache_local_plaintext: false
  mapper?.pack_file ?? mapper?.file ?? "pack_file"
  this.writePackCas(contentHash, data)
  this.putPackFileBlob(contentHash, data)
  file_blob_pointer_not_persisted:
  LASTGIT_PACK_FILE_BLOB_STRICT === "1"
  pack bytes are CAS-only
  if (sha256(plaintext) === contentHash) return plaintext;
  if (unframed && sha256(unframed) === contentHash) return unframed;
  return null;
  const packs = await this.listPacks(repo!, { thin: true, states: ["available"] });
  if (!verifyPointers) {
  if (status === "resolved") {
  skipped += 1
  */
  async backfillPackCover(repo: string) {
    return repo;
  }
  private async putPackFileBlob(contentHash: string, data: Buffer) {
    return data;
  }
  async putPackBlob(contentHash: string, data: Buffer): Promise<void> {
    return;
  }
  private static packBytesFromFileBlobPlaintext(contentHash: string, plaintext: Buffer) {
    return plaintext;
  }
  async backfillPackFileBlobs(repo?: string) {
    return repo;
  }
}

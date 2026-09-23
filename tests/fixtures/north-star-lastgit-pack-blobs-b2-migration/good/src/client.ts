export class NodeClient {
  private async putPackFileBlob(contentHash: string, data: Buffer): Promise<unknown | null> {
    const additionalFields = { content_hash: contentHash, size: String(data.length), data: "" };
    const res = await this.req("POST", "/api/db/file-blob", {
      field: mapper?.pack_file ?? mapper?.file ?? "pack_file",
      key: { hash: contentHash, range: null },
      bytes_b64: plaintext.toString("base64"),
      cache_local_plaintext: false,
      additional_fields: additionalFields,
    });
    return res;
  }

  async putPackBlob(contentHash: string, data: Buffer): Promise<void> {
    this.writePackCas(contentHash, data);
    try {
      filePointer = await this.putPackFileBlob(contentHash, data);
      if (filePointer && NodeClient.verifiedFileBlobPointer === false) {
        throw new Error(
          `file_blob_pointer_not_persisted: uploaded ${contentHash.slice(0, 12)} and the node returned a pointer`,
        );
      }
    } catch (err) {
      if (process.env.LASTGIT_PACK_FILE_BLOB_STRICT === "1") throw err;
    }
    if (fileBlobError) {
      console.error("lastgit: warning: pack bytes are CAS-only");
    }
    await this.mutate([
      { fields: { content_hash: contentHash, size, data: "" } },
    ]);
  }

  private static packBytesFromFileBlobPlaintext(contentHash: string, plaintext: Buffer): Buffer | null {
    if (sha256(plaintext) === contentHash) return plaintext;
    const unframed = unframePackBytes(plaintext);
    if (unframed && sha256(unframed) === contentHash) return unframed;
    return null;
  }

  async backfillPackFileBlobs(repo?: string) {
    const packs = await this.listPacks(repo!, { thin: true, states: ["available"] });
    if (existingPointer) {
      if (!verifyPointers) {
        skipped += 1;
        continue;
      }
      if (status === "resolved") {
        skipped += 1;
        continue;
      }
    }
    if (!verifiedPointer) {
      throw new Error(
        `file_blob_pointer_not_persisted: uploaded ${blob.content_hash.slice(0, 12)} and the node returned a pointer`,
      );
    }
    return packs;
  }
}

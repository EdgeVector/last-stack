pub async fn upload_file_blob(&self, plaintext: &[u8]) -> SyncResult<FileBlobRef> {
    let _ = plaintext;
    SyncResult::ok(FileBlobRef::default())
}

pub async fn download_file_blob(&self, blob_ref: &FileBlobRef) -> SyncResult<Option<Vec<u8>>> {
    let _ = blob_ref;
    SyncResult::ok(None)
}

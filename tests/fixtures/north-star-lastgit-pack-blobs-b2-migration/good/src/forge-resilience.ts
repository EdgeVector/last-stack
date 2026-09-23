checks.push({
  name: "pack_blob_durability",
  status: "ok",
  detail: dereferenced
    ? "every available pack has a file-blob pointer that DEREFERENCES"
    : "add `verify-pointers` for a durability verdict (one fetch per pack)",
});
checks.push({
  name: "pack_blob_durability",
  status: "ok",
  detail: "per-pack plane census not run",
});

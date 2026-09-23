const packBlobDurabilityAudit = args.flags.has("pack-blob-durability-audit");
if (packBlobDurabilityAudit) {
  packBlobDurability = await auditPackBlobDurabilityForDoctor(client, repos, deref);
}

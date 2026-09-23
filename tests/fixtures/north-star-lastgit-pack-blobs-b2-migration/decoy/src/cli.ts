// const packBlobDurabilityAudit = args.flags.has("pack-blob-durability-audit");
const packBlobDurabilityAudit = false;
auditPackBlobDurabilityForDoctor(client, repos, deref);
if (packBlobDurabilityAudit) {
  return;
}

"""Closed H-to-M source tuples; no general path allowance."""

EXACT_CHANGES = {
    '.github/workflows/native-record-transfer.yml': [
        ['100644', 'blob', '081510307770d427d187639f58041f471f23e563'],
        None],
    '.github/workflows/pr282-write-latency.yml': [
        ['100644', 'blob', 'f43bd1d3f424093b82fa37bd4fc0b3929da06fb6'],
        None],
    '.github/workflows/release.yml': [
        ['100644', 'blob', '2c249ab6fa12c259694893b3c048cddf2e557d40'],
        ['100644', 'blob', '71b25d63a5d70da8c56ff241a774cb9b4b720f97']],
    '.gitignore': [
        ['100644', 'blob', 'b60e0506e9475bb3220a99e22f4ca8ab1d6a12a1'],
        ['100644', 'blob', 'caf0a86c7b1df090cd1f3554e84e3f5925ce4f1b']],
    'deny.toml': [
        ['100644', 'blob', 'b109e1122aee0d6be957be887c18677c22ace7cb'],
        ['100644', 'blob', '7f7eb2b18a5a6b4b79611961226a3ab98673bc81']],
    'docs/RELEASING.md': [
        ['100644', 'blob', '4adfb1e2f76025aa9e09736684b3798912f2bea2'],
        ['100644', 'blob', '56846b9ba4ce28bdcba3918f900143e49112d3e1']],
    'docs/designs/lastdb-kernel-constitution.md': [
        ['100644', 'blob', '22901377f2def7168f482e0c8407e8fd839a2bc6'],
        ['100644', 'blob', 'f308dbe24db3b3864aaa8940d394362cbeb4a9cc']],
    'docs/designs/schema-root-data-attribution-and-safe-reclaim.md': [
        ['100644', 'blob', 'e87ae867af7d218561d546076de384e8a4a829f5'],
        ['100644', 'blob', '46c2b769439376d2561a45b05ad17d2f2d69e764']],
    'docs/designs/typed-range-field-contract.md': [
        ['100644', 'blob', '8162c7e6f73ace909f85bff62b44f9ac71e786d5'],
        ['100644', 'blob', '4c5400eff6e9d1eac67730ec778e335e45f7c83a']],
    'docs/lastdb-atom-counter.md': [
        ['100644', 'blob', '0fd36139df541440d5a9cca0f519f8205c54642c'],
        ['100644', 'blob', '8b4edf1dad484714e0d3c291a3320c898a828e46']],
    'docs/lastdb-disk-file-lifetime.md': [
        ['100644', 'blob', '500d97eb25372772818b1c788183d106e49e4747'],
        ['100644', 'blob', 'e89930d5090cd55fb732a0ef24503f663f852902']],
    'docs/lastdb-disk-native-home.md': [
        ['100644', 'blob', '3beaf7af14601bdbe5df05504416e94d1c90601a'],
        ['100644', 'blob', 'feba5d0a13721e4d9e03155e7c2eaa8fb6c30909']],
    'docs/lastdb-disk-native-node.md': [
        ['100644', 'blob', 'ce08efb8b1e5b5b1d9b68f9b54d0512ef7a7b511'],
        ['100644', 'blob', '7412c1d93c9a02a14e2e62f508d4ad16017db4b5']],
    'docs/lastdb-disk-pack-ranges.md': [
        ['100644', 'blob', '4ca72399f102bdd24a2161729b28e133dd247e9e'],
        ['100644', 'blob', 'd75f6a0bbe47ce57697042d5927e03cc1e2e0b66']],
    'docs/lastdb-disk-pack-reader.md': [
        ['100644', 'blob', '9a2145da17c3ad0f1b8f7fb544d6c3a60b491956'],
        ['100644', 'blob', 'b949c865683069d1ce3df2a0bc1f13d623efd180']],
    'docs/lastdb-ideal-storage-shape.md': [
        ['100644', 'blob', '0aa43f1b05bbe214d95077be4b1ab68dc82201ec'],
        ['100644', 'blob', '048b9881b7328443f4ac0f3466ae4051ec3873e4']],
    'docs/lastdb-key-byte-cost.md': [
        ['100644', 'blob', '563ec0e36da040fe21686f646d16f23ff0eb373f'],
        None],
    'docs/lastdb-laststore-storage-boundary.md': [
        ['100644', 'blob', '89cd1c1c9a46ca39cad269ffc94bfb730b061c3c'],
        ['100644', 'blob', '73b380947dfc09e0a71d6dcf864d664462e8a18d']],
    'docs/lastdb-searchable-snapshot-one-pager.md': [
        ['100644', 'blob', '802cb2b9791ce39acf4862c22c54c0ca3fd5f9c2'],
        ['100644', 'blob', '393a16d3f2111480b84e6ba54cd9d4b91f66b199']],
    'docs/lastdb-snapshot-commits.md': [
        ['100644', 'blob', 'b433382d78e795d17e3aea736b70d8d2a807e306'],
        ['100644', 'blob', 'c432ad421c6696d6b440111a8b0bef65fe327249']],
    'docs/operations/write-path-durability-knobs.md': [
        ['100644', 'blob', '0ffcf7b72dd674770831957d5ca3b8e5312bfb75'],
        ['100644', 'blob', 'bd107118a2adaed05d887a119ab58de362a9ef1f']],
    'docs/physical-atom-delete-proof.md': [
        ['100644', 'blob', '43bb7ddffad32541e552e4542d2799f729fc368c'],
        None],
    'docs/proofs/eager-durable-queue-20261023/run.py': [
        ['100644', 'blob', '757e86aad3b5b735a8e0a0ee2c5742d9155b46f9'],
        None],
    'docs/proofs/eager-durable-queue-20261023/semantics.py': [
        ['100644', 'blob', '7586b6efb7e5f218dcbde3cb392831f15d496c60'],
        None],
    'docs/proofs/eager-durable-queue-20261023/tier_base.py': [
        ['100644', 'blob', 'be9f3bdd3987f2fc6a120f4fe4f1e02f2bc2975b'],
        None],
    'docs/proofs/matched-write-concurrency-20261023/capture.py': [
        ['100644', 'blob', '302c8cee2efd47cda67a915e1f4f1bcb624842af'],
        None],
    'docs/proofs/matched-write-concurrency-20261023/run_pairs.py': [
        ['100644', 'blob', 'ea3fac4f4b0369914e7f702d4c4268663c71334c'],
        None],
    'docs/security/tip-family-dual-read-sunset.md': [
        ['100644', 'blob', '0f719804fe31bc4bf4069621ddc078e50943fa79'],
        ['100644', 'blob', 'c47b66ea6671e2886ad8665d3fe20181aa4b6b95']],
    'fold_db/README.md': [
        ['100644', 'blob', '04317b146c9a26b8692b8e94eac0d520f6838722'],
        ['100644', 'blob', '08c18f15201fe0ffa23a3a772a800da30c189af1']],
    'fold_db/crates/core/probes/keep_small_persist_whole_map.py': [
        ['100644', 'blob', 'ccc017f470fc17d7a7c0e52b437c368c0b91bf69'],
        None],
    'fold_db/crates/core/src/atom/molecule_key_codec.rs': [
        ['100644', 'blob', 'b808a24a69a6629ce750fd2f744a19e1602cfbc2'],
        ['100644', 'blob', 'b8c0b82dcc5e95eacb6832f0e8daaba8f4de3f58']],
    'fold_db/crates/core/src/atom/molecule_key_codec/conversion.rs': [
        ['100644', 'blob', 'b62c4ce79c25030810bc56f97bb45b64f0ca8232'],
        ['100644', 'blob', 'eaf95c4ad4c89e7e1dd3826f96388ebbc506efc0']],
    'fold_db/crates/core/src/atom/molecule_key_codec/encoding.rs': [
        ['100644', 'blob', '6fb01171533c07b0370c7815462106540c5ec49b'],
        ['100644', 'blob', '5ba2ae2a23d3683682622b0ddf1c596427892816']],
    'fold_db/crates/core/src/atom/molecule_key_codec/storage_profile.rs': [
        ['100644', 'blob', '16b76605b568730619fa18ee2f2d429827eccab7'],
        ['100644', 'blob', 'f3e145035ab9d65fae05313d38ebd296475d487d']],
    'fold_db/crates/core/src/crypto/at_rest/compress.rs': [
        ['100644', 'blob', '23033f05fead44150c9c0b1a7dd0ac484db4c54e'],
        ['100644', 'blob', 'c968a3fa751acd3f902a778e888e537c42af8b83']],
    'fold_db/crates/core/src/crypto/at_rest/config.rs': [
        ['100644', 'blob', '9010f7488c74182a7b61c130acdd04d9f1e9cfef'],
        ['100644', 'blob', 'ba1c1795b4038b169b98946a0bf6376861cc67d4']],
    'fold_db/crates/core/src/crypto/at_rest/mod.rs': [
        ['100644', 'blob', '3e321a070432c96ca0cc4fca3062f210f2a26ab8'],
        ['100644', 'blob', '6ec290bdd5809b479bf87269ef8fdab2530d6d58']],
    'fold_db/crates/core/src/crypto/at_rest/owned.rs': [
        ['100644', 'blob', '7fd8b66e3a4377c06d85b1c64d4361909723413c'],
        None],
    'fold_db/crates/core/src/crypto/at_rest/stats.rs': [
        ['100644', 'blob', '598459d4d080343b846ba2d989637c31432f4bc2'],
        ['100644', 'blob', '18567d23bf3fbb56ff6cbd8347e996382f8a0579']],
    'fold_db/crates/core/src/crypto/envelope/mod.rs': [
        ['100644', 'blob', 'dbb1ad3a5dadb41e6f62c3922c5b289349cdc36d'],
        ['100644', 'blob', '90f06175cc815c6f8a5ddffb4555523ae1136b1b']],
    'fold_db/crates/core/src/crypto/mod.rs': [
        ['100644', 'blob', 'dda62e6854b1c1c6b0e95bbf8f92fac2ad2d0a69'],
        ['100644', 'blob', '987806cbd8efa73824a4c65b8f0fd40d4d4ce6ce']],
    'fold_db/crates/core/src/db_operations/atom_store/types.rs': [
        ['100644', 'blob', 'f85bba8e6efe7752fbe62fc2000a06da279a4d77'],
        ['100644', 'blob', '3d08c6bac115af95704ef41f5c5cd91fa31b700c']],
    'fold_db/crates/core/src/db_operations/storage_breakdown.rs': [
        ['100644', 'blob', '7f4c9cc883ee4dc62a43ac376cead056ed71ea62'],
        ['100644', 'blob', '954cbc15fb30df8e72e7bbcf09df6dcd0f0b316b']],
    'fold_db/crates/core/src/error_context.rs': [
        ['100644', 'blob', 'bf2a075072dd30a10863534403b1962e47c466e6'],
        ['100644', 'blob', '7114a627b5e2ffaa6d80deae00cc354d91b8e0f5']],
    'fold_db/crates/core/src/fold_db_core/fold_db.rs': [
        ['100644', 'blob', '65e14dcd2bf89caf8a9a827ca34e73dbf43e0dcd'],
        ['100644', 'blob', 'cb05e84759cb3a6c64a727587ddb82fef657a36a']],
    'fold_db/crates/core/src/fold_db_core/fold_db/admin_db.rs': [
        ['100644', 'blob', '0bd1fd502bb84acf2d41aeed5d2b3b147a82e59c'],
        ['100644', 'blob', 'f4db67ec270a3287f3080aab0206ff215e764b0f']],
    'fold_db/crates/core/src/fold_db_core/fold_db/admin_db/maintenance.rs': [
        ['100644', 'blob', '4787326f4ff6945a497828aaee7f1835105459ed'],
        ['100644', 'blob', 'e253d5d7b3028409addd94f717e2ba3c7e341316']],
    'fold_db/crates/core/src/fold_db_core/fold_db/admin_db/retention.rs': [
        ['100644', 'blob', '231dec887d82a4ff6a11acae7f4b324dd6cdf054'],
        None],
    'fold_db/crates/core/src/fold_db_core/fold_db/init.rs': [
        ['100644', 'blob', '7a10e210ab51888861607f7ea42c5a531ec3b309'],
        ['100644', 'blob', '601c591d7224e8846f6901990fea61b79a77a397']],
    'fold_db/crates/core/src/fold_db_core/fold_db/init_boot.rs': [
        ['100644', 'blob', 'b3711e4a921f024001b016b49e1483523b07cff8'],
        ['100644', 'blob', '98e9fb4e9339a72cb36426ebed2ce2ffaf34d1ac']],
    'fold_db/crates/core/src/fold_db_core/fold_db/lifecycle.rs': [
        ['100644', 'blob', 'c8e4caf4c543004205377242e1e0718b2e01f5dd'],
        ['100644', 'blob', '385b0b8c894c8285473039fd664d911e5cb4c799']],
    'fold_db/crates/core/src/fold_db_core/fold_db/sync.rs': [
        ['100644', 'blob', 'f267b78faa6a1c3ae7490be6db3c54ebb38ac37d'],
        ['100644', 'blob', '84589a1859b099269b2ba4b09306c22c49d321ca']],
    'fold_db/crates/core/src/fold_db_core/fold_db/sync/status.rs': [
        ['100644', 'blob', '66e62d1be97e8c9fec8cdb15bd62a123168ca96a'],
        None],
    'fold_db/crates/core/src/fold_db_core/mod.rs': [
        ['100644', 'blob', '55b453a8890a49144b2142d6c0dd87725f7dcb1d'],
        ['100644', 'blob', '0e34fc068bb1209e10f8c3758ebf91be6d4ce3d2']],
    'fold_db/crates/core/src/fold_db_core/mutation_flush.rs': [
        ['100644', 'blob', '3dce3a20f9d9852355adf4dbb87b9e82a52eee67'],
        ['100644', 'blob', 'f19e4a046dc3338b629e4b4082961c4a0870fea3']],
    'fold_db/crates/core/src/fold_db_core/sync_coordinator.rs': [
        ['100644', 'blob', '005601b73b535cb88fd2d900cbf54b2928150229'],
        None],
    'fold_db/crates/core/src/fold_db_core/sync_coordinator/cadence.rs': [
        ['100644', 'blob', 'e0c6074c5430203631eb8226d79f6060ad382b49'],
        None],
    'fold_db/crates/core/src/fold_db_core/sync_coordinator/shutdown.rs': [
        ['100644', 'blob', 'd792c8f0358cb37633dc9ec1212c3d40b75183e5'],
        None],
    'fold_db/crates/core/src/mini_cutover/mod.rs': [
        ['100644', 'blob', 'cc7d74c4a77a92f054aeb06e79251782fd6fed0c'],
        ['100644', 'blob', '870918313c5181bf07320b40b2b6559d6bc02096']],
    'fold_db/crates/core/src/mini_cutover/plane_roles.rs': [
        ['100644', 'blob', 'c774df4a159476f1a3348a68210aabc8f4eefb60'],
        None],
    'fold_db/crates/core/src/mini_cutover/plane_roles/disk.rs': [
        ['100644', 'blob', 'aa0ecbc1349908c0688545e86ac34822d3fcaab2'],
        None],
    'fold_db/crates/core/src/schema/types/field/common.rs': [
        ['100644', 'blob', '15e933fce8ce48f62c771b51881a3c6bb3217162'],
        ['100644', 'blob', 'f6fb99d390059072a4392e3dad71637717f715bc']],
    'fold_db/crates/core/src/storage/disk_pack/kv.rs': [
        ['100644', 'blob', '1867886757a13e6290e3eb4a873c2a33ce0ae41d'],
        ['100644', 'blob', 'a17e905b9a5d69f29c328be2b98819364090290b']],
    'fold_db/crates/core/src/storage/disk_pack/mod.rs': [
        ['100644', 'blob', '353701076e7bce2d57285374e7e2ddd48677e904'],
        ['100644', 'blob', 'a9740a599187e020944c00c9f0243056af32802f']],
    'fold_db/crates/core/src/storage/disk_pack/range_inventory.rs': [
        ['100644', 'blob', '233ca70d4ae1d87ec103cd0c6636dbd051ac01b2'],
        ['100644', 'blob', '513844579cebe00d42cf2e990c0827d2ac7419d2']],
    'fold_db/crates/core/src/storage/disk_pack/range_inventory/catalog.rs': [
        ['100644', 'blob', 'c497828ecaa0b56b19591427bd5c1096b8b056dc'],
        ['100644', 'blob', '2e26c9246e5cf3cc55a43e972b484930e56052e0']],
    'fold_db/crates/core/src/storage/disk_pack/range_inventory/keys.rs': [
        ['100644', 'blob', 'cbd131d185b2806ff2973e6538f2fef81e17e9b4'],
        ['100644', 'blob', '9fafe629c30628562f0c62f50006ab2ad16a3677']],
    'fold_db/crates/core/src/storage/disk_pack/range_inventory/source.rs': [
        ['100644', 'blob', 'c45f5b7fa53e467c444c56374ae9e9face2ddb38'],
        ['100644', 'blob', '236dc98a8f08e5beb6240328f0f3b39f977943ea']],
    'fold_db/crates/core/src/storage/encrypting_namespaced_store/store_impl.rs': [
        ['100644', 'blob', '9fc840135579a96efcaac7b52d1ed2828df94761'],
        ['100644', 'blob', 'f71d28356fa082bb692696f22f9b3e9dede020bc']],
    'fold_db/crates/core/src/storage/encrypting_store/kv_store_impl.rs': [
        ['100644', 'blob', 'f52996a8615d061611d0fe260bbd159905ff3cd4'],
        ['100644', 'blob', '37202315d6e4172635cdfb9e8debd87956b11ad7']],
    'fold_db/crates/core/src/storage/encrypting_store/mod.rs': [
        ['100644', 'blob', '98a2f0a9b5aa1dd9810cddd05d8374e1c43d6ac7'],
        ['100644', 'blob', 'd85b6211fa713b33c5fec7b5e83a939cc8b449ce']],
    'fold_db/crates/core/src/storage/error.rs': [
        ['100644', 'blob', 'aea8a5f130f25ff99b9092efbb0badb33edc0b4e'],
        ['100644', 'blob', '8920c2480626169ce05fcdb0d7025d0f77310b42']],
    'fold_db/crates/core/src/storage/laststore/backup_descriptor.rs': [
        ['100644', 'blob', '8e72a2217d35cd7071056abc816fed806910b4c1'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest.rs': [
        ['100644', 'blob', '8e16217ffec052c86f4641d65472c7047675847a'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/atom_copy.rs': [
        ['100644', 'blob', 'dede5ce2ac654f75994242eba4024c50fe0d81dd'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/atom_lineage.rs': [
        ['100644', 'blob', '1f9f7856b840af29302771a9232e984215dbfae3'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/chain.rs': [
        ['100644', 'blob', '0f2b34efd53f39c6de1dcb43fc1ebaa8f1304382'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/chunk_sha_memo.rs': [
        ['100644', 'blob', 'd06ff48f140a0a92934633a8f8a1fa405257e9ce'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/cut.rs': [
        ['100644', 'blob', 'db1573fdc2deb76cfd2c3822eff81b0c23108eb4'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/deletion_receipt.rs': [
        ['100644', 'blob', 'ee33d1baa6a00be498ec57ff7501a165b44f8fce'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/exclusions.rs': [
        ['100644', 'blob', '6a9d653996fec80eee28c690aa927b284ecb8c02'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/local_recovery.rs': [
        ['100644', 'blob', '82e96e2f2bb36a47ca43faf3a0c1e7d85238cd6f'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/packs.rs': [
        ['100644', 'blob', '60e39328787d7ab0f8eb08acee0158210a712119'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/retirement_receipts.rs': [
        ['100644', 'blob', '440237ab1e1d9c52db427b201eae912792a4299b'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/retirements.rs': [
        ['100644', 'blob', '767615392a1b206e449968a27e36698ec1b79d19'],
        None],
    'fold_db/crates/core/src/storage/laststore/backup_manifest/scan.rs': [
        ['100644', 'blob', '9d0789d0d9f14b044318a768a071a0a5ec56e76e'],
        None],
    'fold_db/crates/core/src/storage/laststore/compact_dispatch.rs': [
        ['100644', 'blob', 'b5231cbaa6780133622bde03d0fcc865fd84482c'],
        None],
    'fold_db/crates/core/src/storage/laststore/high_water.rs': [
        ['100644', 'blob', 'fb0121569d5bb8faa1eabee83c17c4019299a86a'],
        None],
    'fold_db/crates/core/src/storage/laststore/kv_store_impl.rs': [
        ['100644', 'blob', 'c61da76f72f2f459b7eb70b2fc17888be9b07c9e'],
        None],
    'fold_db/crates/core/src/storage/laststore/mod.rs': [
        ['100644', 'blob', 'a7e1c5492c03afb93b6c29f768fde1447024e51b'],
        ['100644', 'blob', '2e61fb06750ab80ee7b9b98611c0d8293b886d4b']],
    'fold_db/crates/core/src/storage/laststore/namespaced_maintenance.rs': [
        ['100644', 'blob', 'bdcdb2c157e0faace771db53a2265ba58b4b68f8'],
        None],
    'fold_db/crates/core/src/storage/laststore/namespaced_maintenance/backup.rs': [
        ['100644', 'blob', 'a00f376804ab72797381335010d9f29c2999a5e8'],
        None],
}

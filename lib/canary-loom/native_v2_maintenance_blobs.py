"""Closed Git modes and blobs for the reviewed native5 retirement fixes."""

# These are source policy identities, not generated CI evidence.
# Baseline: 96f32b2ade27927019179fb57dc60f9c00a0ae68
# Reviewed native5 source: 4c67d497bba752c4417f88932e34cfb4a9e61757
EXACT_BLOBS = {
    'fold_db/crates/core/src/backup_progress/mod.rs': (
        ('100644', 'blob', '329ef97fa71f59cd310d00886558d0bf2a2c8899'),
        ('100644', 'blob', 'b1eb87b9ac6ad2dd71dda94e3ccbd3594731f11a'),
    ),
    'fold_db/crates/core/src/db_operations/atom_store/atoms.rs': (
        ('100644', 'blob', '5f38b83977e8861e6d588af0efdddc62b80625ca'),
        ('100644', 'blob', '5f8c24c4100251a09b64b5afa89168167c5dff99'),
    ),
    'fold_db/crates/core/src/db_operations/atom_store/atoms/events.rs': (
        ('100644', 'blob', 'b24bd4b82268f25619d83f06357fed6ae7a194f5'),
        None,
    ),
    'fold_db/crates/core/src/db_operations/atom_store/conflict_record/mod.rs': (
        ('100644', 'blob', '979072765d306bbd3eb327a43539ebfdea7b7f16'),
        ('100644', 'blob', '5044ad412640dc2a3b39f21db6962f42cb226551'),
    ),
    'fold_db/crates/core/src/db_operations/atom_store/locks.rs': (
        ('100644', 'blob', '222d671aa201f2a528c3a213c36d30f1ab19ea53'),
        ('100644', 'blob', '3dd97a312d9c17b023ce0919ad7a19f18a5dbb0a'),
    ),
    'fold_db/crates/core/src/db_operations/atom_store/retired_intent_retention.rs': (
        ('100644', 'blob', '33d23c8eae1da0c36aac6a4d7da83d3c4bd4710b'),
        ('100644', 'blob', '69cbce600a90d3ce0e27c53387e41fbda69fc35f'),
    ),
    'fold_db/crates/core/src/db_operations/atom_store/retired_intent_retention/storage.rs': (
        ('100644', 'blob', '6d30e049e1bdbd190302f7250771286c176bc7d4'),
        ('100644', 'blob', 'e9fdb2a7530dcf62206232b491ba086d7427e61b'),
    ),
    'fold_db/crates/core/src/db_operations/retired_intents.rs': (
        ('100644', 'blob', 'd6daa4cc791e25a6e1e85ef5a3e6415d6ba2cbb5'),
        ('100644', 'blob', '383bd776ce1f7483ae729cc369356f0b45ca569a'),
    ),
    'fold_db/crates/core/src/db_operations/retired_intents/pointer.rs': (
        ('100644', 'blob', '20bed2d8691ba0ed0ad2ff2950618e981e6ca4ed'),
        ('100644', 'blob', '85a0dc91d7b8ebb388a9c90199de44d0c0482aeb'),
    ),
    'fold_db/crates/core/src/db_operations/schema_store/replay_catalog.rs': (
        ('100644', 'blob', '946e6e4b18712c1cbedac62883d72ac950422f13'),
        ('100644', 'blob', '47fec2a0b2f0b94eaa98fb352dbad3868e04bd33'),
    ),
    'fold_db/crates/core/src/db_operations/schema_store/retired_replay.rs': (
        ('100644', 'blob', 'cef662f3ae55bfce2c52eaac46ef1ee56064ef70'),
        ('100644', 'blob', 'dd1be96d9718520aee18511cbc56a9fe6182639b'),
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/aggregate/validate.rs': (
        ('100644', 'blob', 'bb48e958dbbfc0c9966e3ec1f2752021b0191653'),
        ('100644', 'blob', 'f76425f9e1bb0b5bed9b934bc72c07d1e2cbc85e'),
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/aggregate/write_set.rs': (
        ('100644', 'blob', '59c02954d55a79abe7f2413953a1303cdfe94a5d'),
        ('100644', 'blob', '0d14e1aafc23fa590ee38a4056ead1b1bbfbbcfc'),
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/author_clock.rs': (
        ('100644', 'blob', '8670c8d9755e820bbd137ea71cf2190fb370ee98'),
        ('100644', 'blob', 'bce46acf88d6bd004a934ef27ef57f713bd748d0'),
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/retired_replay.rs': (
        ('100644', 'blob', 'e5ba08b141c4875ad79139593eff3e7613eda2ca'),
        None,
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs': (
        ('100644', 'blob', '43302a234b45f3e374ceafd9e0feedbd9d96dfda'),
        ('100644', 'blob', '3a7a0c6c5c345f60c31908a4ed5b2e8cf3c5d9d4'),
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/write/replay.rs': (
        ('100644', 'blob', '5f8e0918ade3401d07e43ccc46c85f77144f81b6'),
        None,
    ),
    'fold_db/crates/core/src/fold_db_core/mutation_manager/write/replay_cutoff.rs': (
        ('100644', 'blob', '18f4cc33a761b117be7ce6f0988ed5919225f666'),
        ('100644', 'blob', 'a52e4bd610ce1f34129d2425815d16a0bc7a9093'),
    ),
    'fold_db/crates/core/src/schema/core/mod.rs': (
        ('100644', 'blob', '95b22be4b6fba8b0c5b0d71d80c60b63fe07b972'),
        ('100644', 'blob', '9954eae0ec917b708402549eea2d8f115b0a1ab5'),
    ),
    'fold_db/crates/core/src/schema/core/replay_reload.rs': (
        ('100644', 'blob', 'c1184220f1d51505e2ed1f7ee957290f6e112db7'),
        None,
    ),
    'fold_db/crates/core/src/storage/disk_pack/view.rs': (
        ('100644', 'blob', 'ec4b6172e48f6884b38c6ab9754627ff8454d9a0'),
        ('100644', 'blob', 'd2fa9e9e34863458a1cf5792d136832f2c7d2d1b'),
    ),
    'fold_db/crates/core/src/storage/laststore/backup_manifest/cut.rs': (
        ('100644', 'blob', '0fb0a6b46cf4961704f358b2e961ad0152c77df1'),
        ('100644', 'blob', 'db1573fdc2deb76cfd2c3822eff81b0c23108eb4'),
    ),
    'fold_db/crates/core/src/storage/laststore/backup_manifest/deletion_receipt.rs': (
        ('100644', 'blob', '5d264dc3289816d14c30938981f15bae7dafa709'),
        ('100644', 'blob', 'ee33d1baa6a00be498ec57ff7501a165b44f8fce'),
    ),
    'fold_db/crates/core/src/storage/laststore/high_water.rs': (
        ('100644', 'blob', '0ccbb40a61e194c97b837af22ae885f9a06d9547'),
        ('100644', 'blob', 'fb0121569d5bb8faa1eabee83c17c4019299a86a'),
    ),
    'fold_db/crates/core/src/storage/laststore/high_water/source_identity.rs': (
        ('100644', 'blob', '7ad96af6dac1473a5e6cccf68873a51758d9e3cc'),
        None,
    ),
    'fold_db/crates/core/src/storage/laststore/namespaced_maintenance/backup.rs': (
        ('100644', 'blob', '3ff76f33e92db677d830994bcbef580a32e35361'),
        ('100644', 'blob', 'a00f376804ab72797381335010d9f29c2999a5e8'),
    ),
    'fold_db/crates/core/src/sync/mutation_intent.rs': (
        ('100644', 'blob', 'ec35b54b1b446598f005a4e35fe42e5bd7794f9e'),
        ('100644', 'blob', 'dcfabaa55c3bb47624600562c1687d4279ba0a3a'),
    ),
    'fold_db/crates/core/src/sync/org_sync.rs': (
        ('100644', 'blob', '2f57acfb0ac77ab34a293c72ef8ce4372b185f29'),
        ('100644', 'blob', '6a6eb8656253af8485c23e083f49b45cf66b8ed9'),
    ),
    'fold_db/crates/core/src/sync/replay_diagnosis.rs': (
        ('100644', 'blob', 'a3a8939055bfa782c409179e9e968b84a3ba800d'),
        ('100644', 'blob', '5f8da8665454ea6ee5515f0387ce5fa6a8b11dce'),
    ),
    'scripts/lints/lint-no-write-path-syncing-store.sh': (
        ('100755', 'blob', '3dba7a49627744e55d0f66737194de260d5163e5'),
        ('100755', 'blob', 'fb17a10fc987fc015581fc5e6a022f708ce3c7bf'),
    ),
    'scripts/lints/lint-diff-file-size.py': (
        ('100755', 'blob', '0614bbbbefcce243ffadde3b30bba54b204dd5ed'),
        ('100755', 'blob', '81a67a7f62ad2b5a95c3faea2b6941614d5776be'),
    ),
    'scripts/lints/lint-diff-fn-size.py': (
        ('100755', 'blob', '4c6772c114497129c90876f39c9b88ed4c4bf926'),
        ('100755', 'blob', '1c0aad966427ae11317e2e57c65dc04608629a71'),
    ),
    'scripts/lints/atom-counter-writers.allow': (
        ('100644', 'blob', '3d2bbfdd69fcc2d1334191585ee1a341ec815b2a'),
        ('100644', 'blob', '7245c06bf10771810d4b204af458bc06a23a7050'),
    ),
}

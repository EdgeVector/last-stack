"""Closed reviewed source-policy entries; no CI output or generated receipts."""

REVIEWED_SOURCE = "ee8a5b78f4d337c26542fea5e38543ef523587f7"
REVIEWED_TREE = "9d82065b4afbe58a312db64ba12a6ee85fc576f7"
# Each value is [before, after]; each entry is [Git mode, type, object ID].
# None denotes absence. No path receives a general modification permission.
EXACT_CHANGES = {
    ".github/workflows/bench-run.yml": [
        ["100644", "blob", "285ade82284de859b4104ba8a85613741331e59c"],
        ["100644", "blob", "30b0900d0e57e33878568875326fab24529c86d9"],
    ],
    ".github/workflows/bench.yml": [
        ["100644", "blob", "0f91cb59bcaf7fb67e617f2d09bfba28341bc086"],
        ["100644", "blob", "bd13746b64d1a16cdec90014a938814e286e507a"],
    ],
    ".github/workflows/ci-required.yml": [
        ["100644", "blob", "2ebf1a3961b0f7a83a5064311bb46e3ee5242774"],
        ["100644", "blob", "a7790e02fc3c896cbbcdba27ca69c62b252adb1f"],
    ],
    ".github/workflows/contract-diff.yml": [
        None,
        ["100644", "blob", "6e62d50dadaace362684fe6271337b8287616e8a"],
    ],
    ".github/workflows/disk-v2-node-proof.yml": [
        ["100644", "blob", "8c4f483401f315b550aa1479e789ace822f521d4"],
        ["100644", "blob", "a173636f128a19a4d5abc4b82695cdf7fcd6b574"],
    ],
    "Cargo.lock": [
        ["100644", "blob", "79668a659c28005c19ada7cd4a0bb1928046178e"],
        ["100644", "blob", "4afd5e70aaaac6367e0343982022a79fedf323d0"],
    ],
    "Cargo.toml": [
        ["100644", "blob", "0e29740754bb98f278aae15b0dc880873c468aa4"],
        ["100644", "blob", "d9fd2ddf2fe5d49147dc7f5906bf915dcef10db7"],
    ],
    "fold_db/README.md": [
        ["100644", "blob", "7a08de8fd96bfa0dc32071fdb04fbf44d8341cac"],
        ["100644", "blob", "04317b146c9a26b8692b8e94eac0d520f6838722"],
    ],
    "fold_db/crates/core/examples/disk_v2_convert_proof.rs": [
        ["100644", "blob", "51e3e0c2269f94a432318bca4b2b73e2da53d6cb"],
        ["100644", "blob", "0845fcecec29c87779803810ada584e6ccc14e20"],
    ],
    "fold_db/crates/core/src/benchmark_database.rs": [
        ["100644", "blob", "24e479ba5dd01f4f45c44001fe2ac804abff365a"],
        ["100644", "blob", "7de758ac448478005cbe1651f5fae2e32dac34a8"],
    ],
    "fold_db/crates/core/src/db_operations/schema_store.rs": [
        ["100644", "blob", "b6b8463d0d0b233db45ad43d77dd88b31ef5a9bc"],
        ["100644", "blob", "08f6de4f55612de0574bba72e9f9e2861c659e23"],
    ],
    "fold_db/crates/core/src/db_operations/schema_store/retention_page.rs": [
        None,
        ["100644", "blob", "52e2042fdec65fcb260b40e63a3273fe3bc0ce56"],
    ],
    "fold_db/crates/core/src/db_operations/search_index/search_rebuild.rs": [
        ["100644", "blob", "402f2169cdb49e3949bf59a5f24f9b4c01e268e6"],
        ["100644", "blob", "d46a9edd54cdc12f50b57bede605822fd232cd21"],
    ],
    "fold_db/crates/core/src/fold_db_core/fold_db/init.rs": [
        ["100644", "blob", "eb48cadacda96fdf3240d3a944e8a6dfbd30f08e"],
        ["100644", "blob", "7a10e210ab51888861607f7ea42c5a531ec3b309"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/cancel.rs": [
        ["100644", "blob", "767319b7c5f739cd2ef3da7e0a6cc1bd8de7a051"],
        ["100644", "blob", "91ba52641ad4c144667634bb952955c5dd483838"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/capture.rs": [
        ["100644", "blob", "84ccf46c6889448ac408c562bf53ee7485f40322"],
        ["100644", "blob", "31d240c0d7719c7fe64a9c62978d88ee08038748"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/codec.rs": [
        ["100644", "blob", "13f869365fac7a22c813b97508faee7950ab00d6"],
        ["100644", "blob", "4e9eefb3decbc5fe848589a07e98776c362cb4ab"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/context.rs": [
        ["100644", "blob", "7f67d2b98fab88f2a14476361f3741095f25ea74"],
        ["100644", "blob", "5ab9c882256ca7ca5eb5cad743ef5643ebb6f24b"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/counters.rs": [
        ["100644", "blob", "59d398268f91ba88e6f98e09c948fff5d640ea2a"],
        ["100644", "blob", "ca281e1d8077539cf2e6ec68d283ac4d860f207c"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/mod.rs": [
        ["100644", "blob", "ac8107a4cc770a7703c1e5f3d11be40265459831"],
        ["100644", "blob", "a3bcf335719b321dfafbac25ce5da3f89c0638a1"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/model.rs": [
        ["100644", "blob", "95e5ce7a65a3f3db9cc26a0456ba9bf782ecdc08"],
        ["100644", "blob", "b21d5fc024117a1d7df351c11d7d8ed3c502ff41"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/planner.rs": [
        ["100644", "blob", "8565e72749080603e732d1daadd7c29bdb320acf"],
        ["100644", "blob", "49fedef66a80077bf3acc6389c9ed9a811043cbe"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/planner/large.rs": [
        ["100644", "blob", "35ce622a67f4ecf1df4a5ab33b5991533701851f"],
        ["100644", "blob", "cd7cb7837a0aabfb6386a5922517e8283414d8a9"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/planner/metadata.rs": [
        ["100644", "blob", "1d085ef901b29667654f8099b82629e2ec2b4b8c"],
        ["100644", "blob", "cfc0eb2aed4fc5c523c3bf029c079887ce22aea0"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/reader.rs": [
        ["100644", "blob", "f662d309c601ccc463b605528b35ab18fd7ca0a1"],
        ["100644", "blob", "82a814b949f6ce5114dbcb49c3917c1f570f5faf"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/record_plan/finish.rs": [
        ["100644", "blob", "31ffa3163786904d076ab3afb827033b86c79d2c"],
        ["100644", "blob", "792b81226938b027312599eca4727225f9571e97"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/run_capture.rs": [
        None,
        ["100644", "blob", "f5048918b7d4879acbbd6698dc52ae18c620345d"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/run_codec.rs": [
        None,
        ["100644", "blob", "dfd773fb57c64db32373207c247500fdda0cd3ab"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/run_source.rs": [
        None,
        ["100644", "blob", "23e9dbad0b8127e9ff13f961a7586486964fee34"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/standalone/capture.rs": [
        ["100644", "blob", "58cbbf4541036a9d5bc272ebb22308275313ef87"],
        ["100644", "blob", "7b8c15425e258eae6967cbd313f58232e0751019"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/byte_backup/terminal.rs": [
        ["100644", "blob", "de0d95134bac4d85d034a49e3c7923ebec957f64"],
        ["100644", "blob", "5cebc14359e9501d72f29ab6d989d94574b3ce90"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/file_dependencies/metadata.rs": [
        ["100644", "blob", "a0dc90be78081f51abe22e5c11259d341ff07b0b"],
        ["100644", "blob", "1e139bd765fa28fbe75a89775ab4d477372f60b2"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/file_dependencies/metadata/generation.rs": [
        ["100644", "blob", "b22aca0b155847a1570f3a26a625762fb6b68270"],
        ["100644", "blob", "e9862e1379a4c12490d72ef36e53bfa20ad252e5"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/file_dependencies/mod.rs": [
        ["100644", "blob", "49df5e0e91910bdf3d264b2867021cad6a85f07b"],
        ["100644", "blob", "5500d85d0dfcd067afe5f635f50277cfb04d1998"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/initialization.rs": [
        ["100644", "blob", "982d9d5f18016b43eb27985658163d818aae2706"],
        ["100644", "blob", "6d42a64995026f18fd6fdfc8dfe861164e28f8af"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/mod.rs": [
        ["100644", "blob", "bffaaec8d49ffcd0cdac48526e30048c41c73d08"],
        ["100644", "blob", "353701076e7bce2d57285374e7e2ddd48677e904"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/range_inventory/source.rs": [
        ["100644", "blob", "5b854037825e36da7a7e1e907017412f0b793c3d"],
        ["100644", "blob", "c45f5b7fa53e467c444c56374ae9e9face2ddb38"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_node.rs": [
        ["100644", "blob", "9e79da12c963bcc4ff6e8fb13d2996ae72c3d3eb"],
        ["100644", "blob", "36d3245022c897e47c4d4aff68287de23d936fcf"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore.rs": [
        None,
        ["100644", "blob", "f875e02a902e7f464c9e0f338157b2af4107b508"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/files.rs": [
        None,
        ["100644", "blob", "455058ca0689014c5bacce7e5a309525e813eb10"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/node.rs": [
        None,
        ["100644", "blob", "ef886e6a810a499ab4c133e55bf025450e9f579c"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof.rs": [
        None,
        ["100644", "blob", "24a2a8a81a604ade5b182df2f9bc13df2b4aa6ff"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof/atoms.rs": [
        None,
        ["100644", "blob", "b70c9e2bce82ff41e80ccc3b43b65b00a55622b2"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof/keys.rs": [
        None,
        ["100644", "blob", "511b2a9f0e71f2de9b97953f26c567ca1860b472"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof/metadata.rs": [
        None,
        ["100644", "blob", "3a8a55cba6962d13ec8b5d38873841e6d052c38b"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof/native.rs": [
        None,
        ["100644", "blob", "d5fb1283a41df3692661e1342174f3148e9ec6f8"],
    ],
    "fold_db/crates/core/src/storage/disk_pack/run_restore/proof/rows.rs": [
        None,
        ["100644", "blob", "bdec4ba9c917b7d796f46f6fdfac1c63341b4deb"],
    ],
    "fold_db/crates/core/src/storage/mod.rs": [
        ["100644", "blob", "b3e48b261c5053bda88be4d0412c4851eeac29a7"],
        ["100644", "blob", "ef48466df85810354fafd396c83a5293b38a1420"],
    ],
    "fold_db/crates/core/src/sync/auth/backup_transport.rs": [
        ["100644", "blob", "9db7d3f7b072e56aec6a97d63957ef92af1a6f5a"],
        ["100644", "blob", "c66c3cf01d62c0066fb22da1efb31fc8bacd8e7b"],
    ],
    "fold_db/crates/core/src/sync/auth/backup_transport/http.rs": [
        ["100644", "blob", "a2a935fdf11722383e9b511dd3dba516334d905d"],
        ["100644", "blob", "affb5e217c725892a278215bae13478bbbba1d0d"],
    ],
    "fold_db/crates/core/src/sync/auth/http.rs": [
        ["100644", "blob", "9eddee62da5be01d3ac20912fc36f2dac95ddbdb"],
        None,
    ],
    "fold_db/crates/core/src/sync/auth/mod.rs": [
        ["100644", "blob", "e632b9e6a62c11981681b36a5745ba4b88301a06"],
        ["100644", "blob", "09cc2b458fbcfdad7affb6286d054caafdf7ad78"],
    ],
    "fold_db/crates/core/src/sync/mod.rs": [
        ["100644", "blob", "4dc089e1269e5d6dd52a6d371df11b77619f6396"],
        ["100644", "blob", "9f0064db56660573385813c8d787314f090ff52c"],
    ],
    "fold_db/docs/observability/egress-classification-notes.md": [
        ["100644", "blob", "755fd8a97d6c1e19911e516fee45b02cae861a31"],
        ["100644", "blob", "14585b23329490aed0021b2cb7f073e246a758db"],
    ],
    "scripts/benchmarks/README.md": [
        ["100644", "blob", "b4a737d20e0431c3c30835713889095bc50c926c"],
        ["100644", "blob", "8e6f19e46f64dcff4a1f4d7a187450db18aebd0a"],
    ],
    "scripts/benchmarks/advisories.py": [
        ["100644", "blob", "2cbfbedc4366046baddd00a55dc0c1031de4168d"],
        ["100644", "blob", "a446c7318ae1345b787ceef8db207fc68fbe2e21"],
    ],
    "scripts/benchmarks/confirm.py": [
        ["100644", "blob", "1c6e82137a457cd53e60d87eadad12c36ad64247"],
        ["100644", "blob", "2fe676cc265bd3bc75fbd68de1e06029a713d016"],
    ],
    "scripts/benchmarks/disk_budget.py": [
        None,
        ["100644", "blob", "b6b4f79f05944a79139cb9d1ef97f06560459570"],
    ],
    "scripts/benchmarks/disk_budget_report.py": [
        None,
        ["100644", "blob", "8b8eb185fec0d74b9db1e5da79de442342940f42"],
    ],
    "scripts/benchmarks/growth.py": [
        ["100644", "blob", "148ad612d93a5212cc1830c954c6e59baa3e6a63"],
        ["100644", "blob", "7baadf6893be8288d7bdccedd31a926b97a2f905"],
    ],
    "scripts/benchmarks/growth_report.py": [
        ["100644", "blob", "b29b4f498f0365ec07a4c264eb6c17f6031879e4"],
        ["100644", "blob", "af2d0e4643cdd1dc321a932d416632e81b9b31c1"],
    ],
    "scripts/benchmarks/node.py": [
        ["100644", "blob", "7c1762a697f817fe84d03c354d6aedeee048641d"],
        ["100644", "blob", "fd9cb0f8fcd27aebce8495d59cb757f13239162f"],
    ],
    "scripts/benchmarks/run.py": [
        ["100644", "blob", "eaa8b77df6ca283f38706b511f2fd3293258402e"],
        ["100644", "blob", "a7408c39bcccb64e65a01cf5c77e6b4159c77050"],
    ],
    "scripts/benchmarks/ttl_latency.py": [
        ["100644", "blob", "03972b54ab8568d4d879732135e65a6133ac295d"],
        ["100644", "blob", "a6286bf3a43658b2e275856ef152b6987409c546"],
    ],
    "scripts/benchmarks/ttl_maintenance.py": [
        ["100644", "blob", "96502cb84745fa98567701dc30504b7a3599a414"],
        ["100644", "blob", "d72e2d2d1326d4385a0dcbe7766449cd909b870d"],
    ],
    "scripts/lints/diff-contract-snapshots.py": [
        None,
        ["100755", "blob", "a7e59845ddd9f20c0361bb5e3845895e5e940b90"],
    ],
    "scripts/lints/generate-contract-snapshot.py": [
        None,
        ["100755", "blob", "845a3d999c7df9bc2e74eabef2875c2fc04f5581"],
    ],
    "scripts/lints/lint-secrets.py": [
        None,
        ["100644", "blob", "535fadff7e55f580d1060cb30f8e2a7af4f341df"],
    ],
    "vendor/lastdb_docstore/.gitignore": [
        ["100644", "blob", "2c96eb1b6517f2617f9ddeae9f07f5fd7bd7ddef"],
        None,
    ],
    "vendor/lastdb_docstore/Cargo.toml": [
        ["100644", "blob", "ceb03f8e5fb0494cf1128329dea83c3090467930"],
        None,
    ],
    "vendor/lastdb_docstore/src/codec.rs": [
        ["100644", "blob", "7929c9844ed494129d346ad1dde35b4783776adf"],
        None,
    ],
    "vendor/lastdb_docstore/src/envelope.rs": [
        ["100644", "blob", "8f0ef7d6d47cf3094f8770a53e16a93edead072c"],
        None,
    ],
    "vendor/lastdb_docstore/src/error.rs": [
        ["100644", "blob", "8791ae5ff1d578a3eea4519b6f257b96cbb7b07d"],
        None,
    ],
    "vendor/lastdb_docstore/src/laststore_backend.rs": [
        ["100644", "blob", "d939cde6ce2259a49e93cfa2f32af2ae1caaf92c"],
        None,
    ],
    "vendor/lastdb_docstore/src/lib.rs": [
        ["100644", "blob", "8c38c03cc3cdcfc7c236271d8688a0a451df638d"],
        None,
    ],
    "vendor/lastdb_docstore/src/segment.rs": [
        ["100644", "blob", "b5ac05d60e8cea2444769daf07e2550e39fe86e0"],
        None,
    ],
    "vendor/laststore/Cargo.toml": [
        ["100644", "blob", "c78b1aaa36fb8d249beeb95f4881200b13b03ecb"],
        ["100644", "blob", "224d41d2564f9fb4f8f6dc804e9ce27e12a53294"],
    ],
    "vendor/laststore/src/disk_run/footer.rs": [
        ["100644", "blob", "b75a168738b1a03681d9c53a85691a594f94ca14"],
        ["100644", "blob", "c3c71a1648908bdf01e0ef882bb86214a81a0be6"],
    ],
    "vendor/laststore/src/disk_run/home/capture.rs": [
        None,
        ["100644", "blob", "1cfc0aec87b45c5f41fb0eca075ef6d1b8584b7a"],
    ],
    "vendor/laststore/src/disk_run/home/manifest.rs": [
        ["100644", "blob", "dbffe0889cb9dda40e317cb5af165291dd718856"],
        ["100644", "blob", "3d9735eca5cc777d4221a7a6a8e21d9ce6a43528"],
    ],
    "vendor/laststore/src/disk_run/home/manifest/bounded.rs": [
        None,
        ["100644", "blob", "d25c6ad301002de6f69b6c3e274e49f60b08cc31"],
    ],
    "vendor/laststore/src/disk_run/home/manifest/reader.rs": [
        None,
        ["100644", "blob", "8882392667bf383143cc41eedd20534be98dd744"],
    ],
    "vendor/laststore/src/disk_run/home/mod.rs": [
        ["100644", "blob", "7313a384301ba11664f5554af942dc2827fb4cc6"],
        ["100644", "blob", "efc7062804910433fbf4465a09ea39d77155b6bb"],
    ],
    "vendor/laststore/src/disk_run/home/range.rs": [
        ["100644", "blob", "71f33c5b45d99dd5730d2df926801454bf502faf"],
        ["100644", "blob", "eb9290be7a66965992406b04e4bfe629e1365623"],
    ],
    "vendor/laststore/src/disk_run/home/range/stream.rs": [
        None,
        ["100644", "blob", "1c3272bd827428bd74d8e267016a69a33d52dbca"],
    ],
    "vendor/laststore/src/disk_run/home/read.rs": [
        ["100644", "blob", "03bc08c9c7081e3085b440c5497b88b1ba79d4a6"],
        ["100644", "blob", "18ae789472c774575cc3a61673875992fe3c81a8"],
    ],
    "vendor/laststore/src/disk_run/home/read_only.rs": [
        ["100644", "blob", "51606663f0ded0f59bdac96973acd90e6afc73e1"],
        ["100644", "blob", "4b11f4d243928153ed2af6fd2c36e4fc767b703b"],
    ],
    "vendor/laststore/src/disk_run/home/stream.rs": [
        None,
        ["100644", "blob", "22e7e137e40dfae17ea240e5d62315181c3e2c14"],
    ],
    "vendor/laststore/src/disk_run/reader.rs": [
        ["100644", "blob", "391fbbf65270fbe053cc7a9583337829f287e9c9"],
        ["100644", "blob", "4fc75150237daf1854d9bfb14172168dc75f1b2a"],
    ],
    "vendor/laststore/src/disk_run/reader/stream.rs": [
        None,
        ["100644", "blob", "20d343637613095c198dae2b991550c7316f7c8c"],
    ],
    "vendor/laststore/src/disk_run/reader/stream/body.rs": [
        None,
        ["100644", "blob", "ae9456bcaa3acf15107f45d179133ea3dd50ef17"],
    ],
    "vendor/laststore/src/frame.rs": [
        ["100644", "blob", "3fa46db5f4782503df6bff13731cab33dad431f5"],
        ["100644", "blob", "7e6374c08945207bc5a77f49991a4bd17e6c0c6c"],
    ],
    "vendor/laststore/src/frame/stream.rs": [
        None,
        ["100644", "blob", "c4494c385bc1dd015559e41bdc46e3f20cc3fb83"],
    ],
    "vendor/laststore/src/frame/stream/gcm.rs": [
        None,
        ["100644", "blob", "14761320626de86e977e5ad1247e48a014281423"],
    ],
    "vendor/laststore/src/frame/stream/source.rs": [
        None,
        ["100644", "blob", "361eeded28bf9f217075128b20b5cb052b3aa7a7"],
    ],
    "vendor/laststore/src/read_receipt_io.rs": [
        ["100644", "blob", "6a6cf992d5af082d15f15c6138065c054ea70fb1"],
        ["100644", "blob", "a2ee1578e4b455dd23ba96da148f1489dd3930d2"],
    ],
}

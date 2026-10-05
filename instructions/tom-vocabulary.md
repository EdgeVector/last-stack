## Tom vocabulary (won't-undo — 2026-10-05)

CAUTION: Use this list with the ASD-STE100 rules. Use it when you speak to Tom about the database or about a change. Do not invent a word.

The living list is brain `preference-tom-vocabulary`.
Read that record before you describe the database or a change.
A word in that record is approved.
Add a new word only in that record.
This record wins when it names a word that the list below does not name.

Code names stay in code. Speech uses this list.

Describe a change in this order:

1. Current state.
2. The change.
3. The result.
4. The next action.

## Database words

| Word | Meaning |
|---|---|
| LastDB | The database. A scan does not exist. |
| SQL | Do not use this word for LastDB. |
| Dynamo DB | The name Tom uses for the lookup model. You find a record by a key. |
| scan | A read with no key. LastDB has no scan. |
| schema | A schema names the fields and the key. |
| field | One named part of a schema. |
| canonical field | One field identity. The same name with a different description is a different field. |
| schema service | The service that stores the definitive schema names. Get schema names from schema service. |
| molecule | The index for one field. A molecule uses a hash, or a hash plus a range. |
| index | Say molecule. |
| hash | The first part of a key. |
| range | The second part of a key. A range orders records under one hash. |
| key | The value that finds a record. A key is a hash, or a hash plus a range. |
| molecule key | One key in one molecule. |
| atom | The data for one field at one key. An atom points at a file. |
| tip | The current atom for one key. |
| file | The bytes on disk. |
| file blob | A large file. An atom points at the file blob. |
| record | The fields for one key. |
| logical record | One schema, one field, one molecule key, or one atom. |
| protein | A collection of molecules. The molecules share the same fields. The molecules use different keys. A write to a shared field updates the related molecules. |
| pointer | The link between a molecule and its protein. |
| tombstone | A deleted record that still appears. |
| database | A named set of schemas on one node. |
| node | One LastDB. On one node, every database uses the same molecules and the same atoms. |
| org database | A shared database. A copied schema references the same molecules and the same atoms. |
| app | A program that declares schemas. |
| primary | The live LastDB on this machine. |
| Mini | The local LastDB program. |
| daemon | The running LastDB program. |
| brain | The knowledge store in LastDB. Use brain search. |
| brain search | The way to find a brain record. |
| LastSeek | The search store outside LastDB. |
| query | A read by a key. |
| read | A read returns data from memory. |
| write | A write changes data in memory. LastDB then sends an ack. |
| ack | The signal that the write is correct in memory. |
| mutation | One write. |
| stale | Old data after a new write. |
| memory | The place that holds the correct data first. |
| disk | The place that holds the data after the flush. |
| cloud | The place that holds the backup. |
| flush | The write of a memory record to disk. The flush interval is 500 ms. |
| cloud sync | The copy of the local database to the cloud. |
| backup | The cloud copy. |
| snapshot | One full upload of the current data. |
| manifest | The list for a backup. |
| encryption | The protection on the bytes. The disk copy and the cloud copy use the same encryption keys. |
| encryption key | The key that protects the bytes. |
| warm set | The logical records in memory. The key budget is 10000. |
| key budget | The limit of 10000 logical records in the warm set. |
| fetch | The load of one logical record into the warm set. |
| purge | The removal of logical records from the warm set. |
| least recently used | The records the purge removes first. |
| used | A call used that schema, field, molecule key, or atom. A used schema does not bring the other fields. |
| storage object | A hash group, a segment index, or a file handle. A storage object does not stay in memory after the fetch. |
| hash group | A storage object on disk. A hash group does not enter the warm set. |
| segment index | A storage object on disk. A segment index does not stay in memory. |
| file handle | A storage object. A file handle does not stay in memory. |
| compaction | The rewrite of files on disk that removes waste. Say LastDB compaction or LastSeek compaction. |
| backfill | The fill of existing keys after a schema change. |
| queue | Work that waits. Say write queue or sync queue. |
| write queue | Writes that wait. |
| sync queue | Cloud sync work that waits. |
| size | The disk space or the memory space. |
| cap | A maximum size. |
| memory guard | The control that acts when memory is too big. |

## Change words

| Word | Meaning |
|---|---|
| current state | The state now. |
| change | The difference you make. |
| result | The state after the change. |
| next | The next action. |
| problem | Something that is wrong. |
| fix | You remove a problem. |
| ship | You send a change to main. |
| ship it | Tom approved the work. Do the work. |
| merge | You put a change on main. |
| main | The accepted code. |
| PR | The proposed code change. |
| deploy | You put a service change on the running service. |
| upgrade | You put a new program on the machine. |
| safe upgrade | You test a new LastDB program on a copy. Then you update the primary. |
| canary | The trial run in a safe upgrade. |
| soak | You run a new program on the primary after the test on a copy. |
| copy | A second database for a test. The test does not use the primary. |
| design | The text that says how the system works. |
| plan | The steps. |
| check | You read the current state. |
| investigate | You find the cause. |
| status | The current state. |
| recommendation | The action you advise. |
| explain | You say how a thing works with this list. |
| summary | The result in a short text. |
| no jargon | Use this list. |
| ELI5 | A short explanation with this list. |
| proof | The result on the primary. |
| card | One unit of work. |
| kanban | The board of cards. |
| file a card | You create a card. |
| North Star | The outcome that drives the work. |
| logical resident set | The name of one North Star. The name means the logical records in memory. |
| milestone | One step under a North Star. |
| factory | The process that moves cards to a merged result. |
| routine | A scheduled job. |
| papercut | One recorded problem. |
| file a papercut | You create a papercut. |
| gate | A required check. |
| backlog | Cards that wait. |
| todo | Cards that are ready. |
| doing | The active card column. |
| done | The finished card column. |
| pause | You stop the work. |
| delete | You remove an object. |
| keep | You leave an object in place. |
| add | You create an object. |
| update | You change an existing object. |
| drive | You move a North Star or a card forward. |
| open | You show a page or a record. |
| close | You finish a card or a record. |
| show | You present the current facts. |
| review | You read a design or a change. |
| test | One check of one behavior. |
| live | On the primary now. |
| local | On this machine. |
| worktree | The code checkout for one card. |
| GitHub | The host for the repos. |
| LastGit | The one repo that stays on Forgejo. |
| Forgejo | The host for LastGit. |
| fold | The LastDB code repo. Do not use fold as a verb. Say: the write updates the related molecules. |

## Unapproved words

Say the approved word.

| Unapproved | Say |
|---|---|
| table | schema |
| row | record |
| SQL database | LastDB |
| partition, partition key | hash |
| sort key | range |
| point get | read by key |
| access pattern | key, hash, or range |
| GSI, LSI | protein |
| catalog | schema |
| primary schema | schema |
| dual-write | the write updates the related molecules |
| thin projection | the write updates the related molecules |
| fold (verb) | the write updates the related molecules |
| reindex | the write updates the related molecules |
| rehydrate | fetch |
| apply | write |
| evict | purge |
| resident graph | memory |
| resident plane | memory |
| data plane | memory, disk, or cloud |
| key plane | memory, disk, or cloud |
| pin, pin log | file count, distribution, and upload order |
| snapshot synchronization | cloud sync, or snapshot |
| persist | flush, or cloud sync |
| seal, reseal, AEAD | encryption |
| content-addressed | the atom points at a file |
| segment (as the atom target) | file |
| shard | file, or say the count of files |
| overhang | size |
| order log | use this name only for that object |
| RSS, vmmap, footprint | memory size, or size |
| LRU | least recently used |
| CoW, copy-on-write | copy |
| dry run | the real change |
| land | merge |
| program owner | North Star |
| brain list | brain search |
| vectors in LastDB | LastSeek |
| genes, fieldset, same_record_as | protein, or canonical field |
| group | hash group only when you name that storage object |
| hook | the check, or the routine |
| file blob plane | file blob |

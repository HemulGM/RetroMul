unit MSX.VDP.SpriteTiming;

interface

// Generated from 47 original SCREEN 5 R18 sprite captures; accuracy-round14.
// Each byte retains its measured RAS, CAS assertion and CAS release.
// Reproduce with codex-work/tools/MeasureMSXVideoFetch.py.

type
  TMSXSpriteReadTime = record
    RAS, CAS, Data: Word;
  end;

const
  MSXSpriteByteField: array[0..11] of Byte = (0, 1, 2, 8, 9, 10, 4, 5, 3, 12, 13, 11);
  MSXSpriteReadOperation: array[0..15] of ShortInt = (0, 1, 2, 8, 6, 7, -1, -1, 3, 4, 5, 11, 9, 10, -1, -1);
  MSXSpriteReadR18: array[0..15, 0..47] of TMSXSpriteReadTime = (
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1327),
    (RAS: 1337; CAS: 1339; Data: 1341), (RAS: 1337; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1336; CAS: 1338; Data: 1340), (RAS: 1336; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1335; CAS: 1337; Data: 1339), (RAS: 1335; CAS: 1342; Data: 1344), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1334; CAS: 1336; Data: 1338), (RAS: 1334; CAS: 1341; Data: 1343), (RAS: 1347; CAS: 1348; Data: 1350), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1334; CAS: 1335; Data: 1337), (RAS: 1334; CAS: 1340; Data: 1342), (RAS: 1346; CAS: 1347; Data: 1349), (RAS: 1353; CAS: 1355; Data: 1357), (RAS: 1353; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1334; CAS: 1335; Data: 1337), (RAS: 1334; CAS: 1339; Data: 1341), (RAS: 1345; CAS: 1346; Data: 1348), (RAS: 1352; CAS: 1354; Data: 1356), (RAS: 1352; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1334; CAS: 1335; Data: 1337), (RAS: 1334; CAS: 1339; Data: 1341), (RAS: 1344; CAS: 1345; Data: 1347), (RAS: 1351; CAS: 1353; Data: 1355), (RAS: 1351; CAS: 1358; Data: 1360), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1322), (RAS: 1315; CAS: 1324; Data: 1326),
    (RAS: 1334; CAS: 1335; Data: 1337), (RAS: 1334; CAS: 1339; Data: 1341), (RAS: 1344; CAS: 1345; Data: 1347), (RAS: 1350; CAS: 1352; Data: 1354), (RAS: 1350; CAS: 1357; Data: 1359), (RAS: 1363; CAS: 1364; Data: 1366),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1292; Data: 1294), (RAS: 1298; CAS: 1299; Data: 1301),
    (RAS: 1305; CAS: 1307; Data: 1309), (RAS: 1305; CAS: 1311; Data: 1313), (RAS: 1305; CAS: 1315; Data: 1317), (RAS: 1319; CAS: 1320; Data: 1322), (RAS: 1319; CAS: 1324; Data: 1326), (RAS: 1319; CAS: 1328; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1297; CAS: 1298; Data: 1300),
    (RAS: 1304; CAS: 1306; Data: 1308), (RAS: 1304; CAS: 1311; Data: 1313), (RAS: 1304; CAS: 1315; Data: 1317), (RAS: 1319; CAS: 1320; Data: 1322), (RAS: 1319; CAS: 1324; Data: 1326), (RAS: 1319; CAS: 1328; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1303; CAS: 1305; Data: 1307), (RAS: 1303; CAS: 1310; Data: 1312), (RAS: 1303; CAS: 1315; Data: 1317), (RAS: 1319; CAS: 1320; Data: 1322), (RAS: 1319; CAS: 1324; Data: 1326), (RAS: 1319; CAS: 1328; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1304; Data: 1306), (RAS: 1302; CAS: 1309; Data: 1311), (RAS: 1302; CAS: 1314; Data: 1316), (RAS: 1318; CAS: 1319; Data: 1322), (RAS: 1318; CAS: 1324; Data: 1326), (RAS: 1318; CAS: 1328; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1308; Data: 1310), (RAS: 1302; CAS: 1313; Data: 1315), (RAS: 1317; CAS: 1318; Data: 1321), (RAS: 1317; CAS: 1323; Data: 1326), (RAS: 1317; CAS: 1328; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1312; Data: 1314), (RAS: 1316; CAS: 1317; Data: 1320), (RAS: 1316; CAS: 1322; Data: 1325), (RAS: 1316; CAS: 1327; Data: 1330),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1319), (RAS: 1315; CAS: 1321; Data: 1324), (RAS: 1315; CAS: 1326; Data: 1329),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)),
    (
    (RAS: 1238; CAS: 1239; Data: 1241), (RAS: 1238; CAS: 1243; Data: 1245), (RAS: 1238; CAS: 1247; Data: 1249), (RAS: 1251; CAS: 1252; Data: 1254), (RAS: 1251; CAS: 1256; Data: 1258), (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273), (RAS: 1270; CAS: 1275; Data: 1277), (RAS: 1280; CAS: 1281; Data: 1283), (RAS: 1286; CAS: 1287; Data: 1289), (RAS: 1286; CAS: 1291; Data: 1293), (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305), (RAS: 1302; CAS: 1307; Data: 1309), (RAS: 1302; CAS: 1311; Data: 1313), (RAS: 1315; CAS: 1316; Data: 1318), (RAS: 1315; CAS: 1320; Data: 1323), (RAS: 1315; CAS: 1325; Data: 1328),
    (RAS: 1338; CAS: 1339; Data: 1341), (RAS: 1338; CAS: 1343; Data: 1345), (RAS: 1348; CAS: 1349; Data: 1351), (RAS: 1354; CAS: 1355; Data: 1357), (RAS: 1354; CAS: 1359; Data: 1361), (RAS: 1364; CAS: 1365; Data: 1367),
    (RAS: 2; CAS: 3; Data: 5), (RAS: 2; CAS: 7; Data: 9), (RAS: 2; CAS: 11; Data: 13), (RAS: 15; CAS: 16; Data: 18), (RAS: 15; CAS: 20; Data: 22), (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37), (RAS: 34; CAS: 39; Data: 41), (RAS: 44; CAS: 45; Data: 47), (RAS: 50; CAS: 51; Data: 53), (RAS: 50; CAS: 55; Data: 57), (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69), (RAS: 66; CAS: 71; Data: 73), (RAS: 66; CAS: 75; Data: 77), (RAS: 79; CAS: 80; Data: 82), (RAS: 79; CAS: 84; Data: 86), (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101), (RAS: 98; CAS: 103; Data: 105), (RAS: 108; CAS: 109; Data: 111), (RAS: 114; CAS: 115; Data: 117), (RAS: 114; CAS: 119; Data: 121), (RAS: 124; CAS: 125; Data: 127)));

implementation

end.


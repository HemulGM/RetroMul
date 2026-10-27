unit MSX.VDP.ShortTiming;

interface

uses
  MSX.VDP.SpriteTiming;

// Generated from published SCREEN 5 S1/S0 captures; R18=0. See accuracy-round16.
const
  MSXSpriteReadShort: array[0..47] of TMSXSpriteReadTime = (
    (RAS: 1238; CAS: 1239; Data: 1241),
    (RAS: 1238; CAS: 1243; Data: 1245),
    (RAS: 1238; CAS: 1247; Data: 1249),
    (RAS: 1251; CAS: 1252; Data: 1254),
    (RAS: 1251; CAS: 1256; Data: 1258),
    (RAS: 1251; CAS: 1260; Data: 1262),
    (RAS: 1270; CAS: 1271; Data: 1273),
    (RAS: 1270; CAS: 1275; Data: 1277),
    (RAS: 1280; CAS: 1281; Data: 1283),
    (RAS: 1286; CAS: 1287; Data: 1289),
    (RAS: 1286; CAS: 1291; Data: 1293),
    (RAS: 1296; CAS: 1297; Data: 1299),
    (RAS: 1302; CAS: 1303; Data: 1305),
    (RAS: 1302; CAS: 1307; Data: 1309),
    (RAS: 1302; CAS: 1311; Data: 1313),
    (RAS: 1315; CAS: 1316; Data: 1318),
    (RAS: 1315; CAS: 1320; Data: 1322),
    (RAS: 1315; CAS: 1324; Data: 1327),
    (RAS: 1335; CAS: 1336; Data: 1338),
    (RAS: 1335; CAS: 1340; Data: 1342),
    (RAS: 1345; CAS: 1346; Data: 1348),
    (RAS: 1351; CAS: 1352; Data: 1354),
    (RAS: 1351; CAS: 1356; Data: 1358),
    (RAS: 1361; CAS: 1362; Data: 1364),
    (RAS: 2; CAS: 3; Data: 5),
    (RAS: 2; CAS: 7; Data: 9),
    (RAS: 2; CAS: 11; Data: 13),
    (RAS: 15; CAS: 16; Data: 18),
    (RAS: 15; CAS: 20; Data: 22),
    (RAS: 15; CAS: 24; Data: 26),
    (RAS: 34; CAS: 35; Data: 37),
    (RAS: 34; CAS: 39; Data: 41),
    (RAS: 44; CAS: 45; Data: 47),
    (RAS: 50; CAS: 51; Data: 53),
    (RAS: 50; CAS: 55; Data: 57),
    (RAS: 60; CAS: 61; Data: 63),
    (RAS: 66; CAS: 67; Data: 69),
    (RAS: 66; CAS: 71; Data: 73),
    (RAS: 66; CAS: 75; Data: 77),
    (RAS: 79; CAS: 80; Data: 82),
    (RAS: 79; CAS: 84; Data: 86),
    (RAS: 79; CAS: 88; Data: 90),
    (RAS: 98; CAS: 99; Data: 101),
    (RAS: 98; CAS: 103; Data: 105),
    (RAS: 108; CAS: 109; Data: 111),
    (RAS: 114; CAS: 115; Data: 117),
    (RAS: 114; CAS: 119; Data: 121),
    (RAS: 124; CAS: 125; Data: 127));

implementation

end.


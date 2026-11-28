// BIOS and installed SIMM CRCs from the FBNeo 1.0.0.03 arcade DAT.
// Each layout lists banks 1–6, eight sockets per bank, in physical order.
const CPS3CDLayouts: array[0..10] of string = (
  'CAD468F8E9721D892889EC985A6CD148--------------------------------' +
  '----------------------------------------------------------------' +
  '83350CC556734DE6800EA0F197E9146C0CB1D6487A1099F0AEFF8F54F770ACD0' +
  '301E56F22048E103C9433455C02171A82DDBF276FEA820A6C7528DF12449CF3B' +
  '424451B99B8CB56B------------------------------------------------' +
  '----------------------------------------------------------------',
  '65BAC346A8EC4AAE2CAF899513EBC21D--------------------------------' +
  '----------------------------------------------------------------' +
  '83350CC556734DE6800EA0F197E9146C0CB1D6487A1099F0AEFF8F54F770ACD0' +
  '301E56F22048E103C9433455C02171A82DDBF276FEA820A6C7528DF12449CF3B' +
  '424451B99B8CB56B------------------------------------------------' +
  '----------------------------------------------------------------',
  'CFC9E45A579205460D8F2680EA4CA054--------------------------------' +
  '----------------------------------------------------------------' +
  '080B3BD35C356F2FF9C97A4509DE3EAD7DD7E1F347A03A3AE9EB7A267F44395C' +
  '9AC080FC6E2C4C948AFC22D49F3873B8166B3C97E5EA2547E85B9FDD362C01B7' +
  '9BC108B2C6F1C066------------------------------------------------' +
  '----------------------------------------------------------------',
  '2D666F0B2A3A8EF6161D220687DED8A3--------------------------------' +
  '94A4CE0F67585033FABFFCD5623C09CA--------------------------------' +
  'DAB2D7661F2AA34B6F1A04EBE05EF205AFFB074F6962872E6EED87DEE18F479E' +
  '764C25033E16AF6E215705E6E30CBD9C4185DED94E8DB01308DF48CEBB8F80A5' +
  'EBDC47876B7C550E56FF8C503F2AC3E948CDA50E520C0AF62EDC598693FFA199' +
  '----------------------------------------------------------------',
  '9516948BA847848D853E8846C04FE00E--------------------------------' +
  'E1A4B3C8189CEF9547DB5EC6E3D3A155--------------------------------' +
  'DE7FC9C143D053D32FFD7FA54DA4985BFDE98D72EDB2A266BE7CF31956FE1A9F' +
  'C4E7BF68B62B271918D158099AF0AD794124C1F05E001FD19AFFA23B2511572A' +
  '797615FC734FD162------------------------------------------------' +
  '----------------------------------------------------------------',
  'CFBC38D642578D941B40C566BBA709B4--------------------------------' +
  '417E5DC1D3B3267DC66D96B1AA34CC85--------------------------------' +
  'DE7FC9C143D053D32FFD7FA54DA4985BFDE98D72EDB2A266BE7CF31956FE1A9F' +
  'C4E7BF68B62B271918D158099AF0AD794124C1F05E001FD19AFFA23B2511572A' +
  '797615FC734FD162------------------------------------------------' +
  '----------------------------------------------------------------',
  'E06BA8866DD177C8D35A15E066D865AC--------------------------------' +
  '417E5DC1C891C8871E101F301FD1D3E4--------------------------------' +
  'DE7FC9C143D053D32FFD7FA54DA4985BFDE98D72EDB2A266BE7CF31956FE1A9F' +
  'C4E7BF68B62B271918D158099AF0AD794124C1F05E001FD19AFFA23B2511572A' +
  '797615FC734FD162------------------------------------------------' +
  '----------------------------------------------------------------',
  '11DFD3CDC50585E68E011D9BDCA8D92F--------------------------------' +
  '06EB969EE7039F82645C96F7610EFAB1--------------------------------' +
  '7BAA1F79234BF8FED9EBC308293CBA776055E747499AA6FC6C13879ECF4F8EDE' +
  '091FD5BA0BCA8917A0FD578B4BF8C699137B87854FB70671832374A41C88576D' +
  'C67D91906CB79868DF69930E333754E078F6D4178CCAD9B185DE59E5EE7E29B3' +
  '8DA690421C8C7AC4A671341D1A99024920CB39AC5F844B2F450E8D28CC5F4187',
  '66E66235186E8C5FBCE18CAB129DC2C9--------------------------------' +
  '06EB969EE7039F82645C96F7610EFAB1--------------------------------' +
  '7BAA1F79234BF8FED9EBC308293CBA776055E747499AA6FC6C13879ECF4F8EDE' +
  '091FD5BA0BCA8917A0FD578B4BF8C699137B87854FB70671832374A41C88576D' +
  'C67D91906CB79868DF69930E333754E078F6D4178CCAD9B185DE59E5EE7E29B3' +
  '8DA690421C8C7AC4A671341D1A99024920CB39AC5F844B2F450E8D28CC5F4187',
  'ADCD8377D7590B59E62E240BC95450C3--------------------------------' +
  '535F2EBA01DD3A0161432672ACDC9ACA--------------------------------' +
  '4D16E1119B3406D3F2414997954B9C7D625ADC1D20A70BB4A10EC5AF0BD0DE7A' +
  '6EA14ADC8F4C42FBEF0586D193CCC4703D9EC7D203E6685001606AC336392B87' +
  '2EF8C60CCF7D7CA6B7815BFA9BFEC049D167536B55E7A0424FB329068C8BE520' +
  '----------------------------------------------------------------',
  '76976231CEDD78E72955B77F280139D7--------------------------------' +
  '305C491418AF4F3B397E5C9EA9D0A7D7--------------------------------' +
  '4D16E1119B3406D3F2414997954B9C7D625ADC1D20A70BB4A10EC5AF0BD0DE7A' +
  '6EA14ADC8F4C42FBEF0586D193CCC4703D9EC7D203E6685001606AC336392B87' +
  '2EF8C60CCF7D7CA6B7815BFA9BFEC049D167536B55E7A0424FB329068C8BE520' +
  '----------------------------------------------------------------');

const CPS3CDSets: array[0..34] of TCPS3CDSet = (
  (Name: 'redearth'; BIOS: $02E0F336; Layout: 0),
  (Name: 'redearthr1'; BIOS: $02E0F336; Layout: 1),
  (Name: 'warzard'; BIOS: $F8E2F0C6; Layout: 0),
  (Name: 'warzardr1'; BIOS: $F8E2F0C6; Layout: 1),
  (Name: 'sfiii'; BIOS: $27699DDC; Layout: 2),
  (Name: 'sfiiiu'; BIOS: $FB172A8E; Layout: 2),
  (Name: 'sfiiia'; BIOS: $CBD28DE7; Layout: 2),
  (Name: 'sfiiij'; BIOS: $74205250; Layout: 2),
  (Name: 'sfiiih'; BIOS: $D2B3CD48; Layout: 2),
  (Name: 'sfiii2'; BIOS: $75DD72E0; Layout: 3),
  (Name: 'sfiii2a'; BIOS: $4518D589; Layout: 3),
  (Name: 'sfiii2j'; BIOS: $FAEA0A3E; Layout: 3),
  (Name: 'sfiii2h'; BIOS: $5C799526; Layout: 3),
  (Name: 'jojo'; BIOS: $513E40EC; Layout: 4),
  (Name: 'jojor1'; BIOS: $513E40EC; Layout: 5),
  (Name: 'jojor2'; BIOS: $513E40EC; Layout: 6),
  (Name: 'jojou'; BIOS: $8D40F7BE; Layout: 4),
  (Name: 'jojour1'; BIOS: $8D40F7BE; Layout: 5),
  (Name: 'jojour2'; BIOS: $8D40F7BE; Layout: 6),
  (Name: 'jojoj'; BIOS: $02778F60; Layout: 4),
  (Name: 'jojojr1'; BIOS: $02778F60; Layout: 5),
  (Name: 'jojojr2'; BIOS: $02778F60; Layout: 6),
  (Name: 'jojoa'; BIOS: $789AA72A; Layout: 4),
  (Name: 'jojoar1'; BIOS: $789AA72A; Layout: 5),
  (Name: 'jojoar2'; BIOS: $789AA72A; Layout: 6),
  (Name: 'sfiii3'; BIOS: $30BBF293; Layout: 7),
  (Name: 'sfiii3r1'; BIOS: $30BBF293; Layout: 8),
  (Name: 'sfiii3u'; BIOS: $ECC545C1; Layout: 7),
  (Name: 'sfiii3ur1'; BIOS: $ECC545C1; Layout: 8),
  (Name: 'sfiii3j'; BIOS: $63F23D1F; Layout: 7),
  (Name: 'sfiii3jr1'; BIOS: $63F23D1F; Layout: 8),
  (Name: 'jojobar1'; BIOS: $63CC8800; Layout: 9),
  (Name: 'jojobajr1'; BIOS: $3085478C; Layout: 9),
  (Name: 'jojobar2'; BIOS: $63CC8800; Layout: 10),
  (Name: 'jojobajr2'; BIOS: $3085478C; Layout: 10));

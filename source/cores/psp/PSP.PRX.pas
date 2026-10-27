unit PSP.PRX;

// PRX protocol implementation, GPL-3.0-or-later. See PSP.PRX-LICENSE.md for
// PPSSPP/libkirk provenance and notices. No external binary is used.

interface

uses
  System.SysUtils, System.Classes;

type
  EPSPPRX = class(EReadError);

function DecryptPSPPRX(const Data: TBytes): TBytes;

implementation

uses
  System.Hash, System.ZLib, PSP.AES;

function DecodeHex(const Text: string): TBytes;
begin
  SetLength(Result, Text.Length div 2);
  for var I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Text.Substring(I * 2, 2));
end;

{ Protocol key data from PPSSPP 68c85fd6942e18dc5f44c1c67268500c0646aaea.
  Credit: PPSSPP, PSARDUMPER/JPCSP and libkirk (C) 2010-2011 Proxima.
  Preserve the upstream GPL notices in PSP.PRX-LICENSE.md. }
function KirkKey(Code: Integer): TBytes;
begin
  case Code of
    $00:
      Result := DecodeHex('2C92E5902B86C106B72EEA6CD4EC7248');
    $01:
      Result := DecodeHex('058DC80B33A5BF9D5698FAE0D3715E1F');
    $02:
      Result := DecodeHex('B813C35EC64441E3DC3C16F5B45E6484');
    $03:
      Result := DecodeHex('9802C4E6EC9E9E2FFC634CE42FBB4668');
    $04:
      Result := DecodeHex('99244CD258F51BCBB0619CA73830075F');
    $05:
      Result := DecodeHex('0225D7BA63ECB94A9D237601B3F6AC17');
    $06:
      Result := DecodeHex('6099F28170560E5F747CB520C0CDC23C');
    $07:
      Result := DecodeHex('76368B438F77D87EFE5FB6115939885C');
    $08:
      Result := DecodeHex('14A115EB434A1BA4905E03B617A15C04');
    $09:
      Result := DecodeHex('E65803D9A71AA87F059D229DAF5453D0');
    $0A:
      Result := DecodeHex('BA3480B428A7CA5F216412F70FBB7323');
    $0B:
      Result := DecodeHex('72AD35AC9AC3130A778CB19D88550B0C');
    $0C:
      Result := DecodeHex('8485C848750843BC9B9AECA79C7F6018');
    $0D:
      Result := DecodeHex('B5B16EDE23A97B0EA17CDBA2DCDEC46E');
    $0E:
      Result := DecodeHex('C871FDB3BCC5D2F2E2D7729DDF826882');
    $0F:
      Result := DecodeHex('0ABB336C96D4CDD8CB5F4BE0BADB9E03');
    $10:
      Result := DecodeHex('32295BD5EAF7A34216C88E48FF50D371');
    $11:
      Result := DecodeHex('46F25E8E4D2AA540730BC46E47EE6F0A');
    $12:
      Result := DecodeHex('5DC71139D01938BC027FDDDCB0837D9D');
    $13:
      Result := DecodeHex('51DD65F071A4E5EA6AAF12194129B8F4');
    $14:
      Result := DecodeHex('03763C6865C69B0FFE8FD8EEA43616A0');
    $15:
      Result := DecodeHex('7D50B85CAF6769F0E54AA8098B0EBE1C');
    $16:
      Result := DecodeHex('72684B32AC3B332F2A7AFC9E14D56F6B');
    $17:
      Result := DecodeHex('201D31964AD99FBF32D5D61C491BD9FC');
    $18:
      Result := DecodeHex('F8D84463D610D12A448E9690A6BB0BAD');
    $19:
      Result := DecodeHex('5CD4057FA13060440AD9B6745F244F4E');
    $1A:
      Result := DecodeHex('F48AD678599C22C1D411933DF845B893');
    $1B:
      Result := DecodeHex('CAE7D287A2ECC1CD94542B5E1D9488B2');
    $1C:
      Result := DecodeHex('DE26D37A39956C2AD8C3A6AF21EBB301');
    $1D:
      Result := DecodeHex('7CB68B4DA38D1DD932679CA99FFB2852');
    $1E:
      Result := DecodeHex('A0B556B469AB368F36DEC9092ECB41B1');
    $1F:
      Result := DecodeHex('939DE19B725FEEE2452ABC1706D14769');
    $20:
      Result := DecodeHex('A4A4E621382EF1AF7B177AE842AD0031');
    $21:
      Result := DecodeHex('C37F13E8CF84DB34747BC3A0F19D3A73');
    $22:
      Result := DecodeHex('2BF7838AD898E95FA5F901DA61FE35BB');
    $23:
      Result := DecodeHex('C704621E714A66EA62E04B203DB8C2E5');
    $24:
      Result := DecodeHex('C933859AAB00CDCE4D8B8E9F3DE6C00F');
    $25:
      Result := DecodeHex('1842561F2B5F34E3513EB78977431A65');
    $26:
      Result := DecodeHex('DCB0A0065A50A14E59AC973F1758A3A3');
    $27:
      Result := DecodeHex('C4DBAE83E29CF254A3DD374E807BF425');
    $28:
      Result := DecodeHex('BFAEEB498265C57C64B8C17E19064409');
    $29:
      Result := DecodeHex('797CECC3B3EE0AC03BD8E6C1E0A8B1A4');
    $2A:
      Result := DecodeHex('7534FE0BD6D0C28D68D4E02AE7D5D155');
    $2B:
      Result := DecodeHex('FAB35326974F4EDFE4C3A814C32F0F88');
    $2C:
      Result := DecodeHex('EC97B386B433C6BF4E539D95EBB979E4');
    $2D:
      Result := DecodeHex('B320A204CF480629B5DD8EFC98D4177B');
    $2E:
      Result := DecodeHex('5DFC0D4F2C39DA684A3374ED4958A73A');
    $2F:
      Result := DecodeHex('D75A5422CED9A3D62B557D8DE8BEC7EC');
    $30:
      Result := DecodeHex('6B4AEE4345AE7007CF8DCF4E4AE93CFA');
    $31:
      Result := DecodeHex('2B522F664C2D114CFE61318C56784EA6');
    $32:
      Result := DecodeHex('3AA34E44C66FAF7BFAE55327EFCFCC24');
    $33:
      Result := DecodeHex('2B5C78BFC38E499D41C33C5C7B2796CE');
    $34:
      Result := DecodeHex('F37EEAD2C0C8231DA99BFA495DB7081B');
    $35:
      Result := DecodeHex('708D4E6FD1F66F1D1E1FCB02F9B39926');
    $36:
      Result := DecodeHex('0F6716E180699C51FCC7AD6E4FB846C9');
    $37:
      Result := DecodeHex('560A494A844C8ED982EE0B6DC57D208D');
    $38:
      Result := DecodeHex('12468D7E1C42209BBA5426835EB03303');
    $39:
      Result := DecodeHex('C43BB6D653EE67493EA95FBC0CED6F8A');
    $3A:
      Result := DecodeHex('2CC3CF8C2878A5A663E2AF2D715E86BA');
    $3B:
      Result := DecodeHex('833DA70CED6A2012D196E6FE5C4D37C5');
    $3C:
      Result := DecodeHex('C743D06742EE90B8CA75503520ADBCCE');
    $3D:
      Result := DecodeHex('8AE3663F8D9E82A1EDE68C9CE8256DAA');
    $3E:
      Result := DecodeHex('7FC96F0BB1485CA55DD364B77AF5E4EA');
    $3F:
      Result := DecodeHex('91B765788BCB8BD402ED553A6662D0AD');
    $40:
      Result := DecodeHex('2824F9101B8D0F7B6EB263B5B55B2EBB');
    $41:
      Result := DecodeHex('30E2575DE0A249CEE8CF2B5E4D9F52C7');
    $42:
      Result := DecodeHex('5EE50439623202FA85393F72BB77FD1A');
    $43:
      Result := DecodeHex('F88174B1BDE9BFDD45E2F55589CF46AB');
    $44:
      Result := DecodeHex('7DF49265E3FAD678D6FE78ADBB3DFB63');
    $45:
      Result := DecodeHex('747FD62DC7A1CA96E27ACEFFAA723FF7');
    $46:
      Result := DecodeHex('1E58EBD065BBF168C5BDF746BA7BE100');
    $47:
      Result := DecodeHex('24347DAF5E4B35727A52276BA05474DB');
    $48:
      Result := DecodeHex('09B1C705C35F536677C0EB3677DF8307');
    $49:
      Result := DecodeHex('CCBE615C05A20033378E5964A7DD703D');
    $4A:
      Result := DecodeHex('0D4750BBFCB0028130E184DEA8D48413');
    $4B:
      Result := DecodeHex('0CFD679AF9B4724FD78DD6E99642288B');
    $4C:
      Result := DecodeHex('7AD31A8B4BEFC2C2B39901A9FE76B987');
    $4D:
      Result := DecodeHex('BE787817C7F16F1AE0EF3BDE4CC2D786');
    $4E:
      Result := DecodeHex('7CD8B891910A4314D0533DD84C45BE16');
    $4F:
      Result := DecodeHex('32722C8807CF357D4A2F511944AE68DA');
    $50:
      Result := DecodeHex('7E6BBFF6F687B898EEB51B3216E46E5D');
    $51:
      Result := DecodeHex('08EA5A8349B59DB53E0779B19A59A354');
    $52:
      Result := DecodeHex('F31281BFE69F51D164082521FFBB2261');
    $53:
      Result := DecodeHex('AFFE8EB13DD17ED80A61241C959256B6');
    $54:
      Result := DecodeHex('92CDB4C25BF2355A2309E819C9144235');
    $55:
      Result := DecodeHex('E1C65B226BE1DA02BA18FA21349EF96D');
    $56:
      Result := DecodeHex('14EC76CE97F38A0A34506C539A5C9AB4');
    $57:
      Result := DecodeHex('1C9BC490E3066481FA59FDB600BB2870');
    $58:
      Result := DecodeHex('43A5CACC0D6C2D3F2BD989676B3F7F57');
    $59:
      Result := DecodeHex('00EFFD1808A405893C38FB2572706106');
    $5A:
      Result := DecodeHex('EEAF49E009879BEFAAD6326A3213C429');
    $5B:
      Result := DecodeHex('8D26B90F431DBB08DB1DDAC5B52C92ED');
    $5C:
      Result := DecodeHex('577C3060AE6EBEAE3AAB1819C571680B');
    $5D:
      Result := DecodeHex('115A5D20D53A8DD39CC5AF410F0F186F');
    $5E:
      Result := DecodeHex('0D4D51AB2379BF803ABFB90E75FC14BF');
    $5F:
      Result := DecodeHex('9993DA3E7D2E5B15F252A4E66BB85A98');
    $60:
      Result := DecodeHex('F42830A5FB0D8D760EA671C22BDE669D');
    $61:
      Result := DecodeHex('FB5FEB7FC7DCDD693701979B29035C47');
    $62:
      Result := DecodeHex('02326AE7D396CE7F1C419DD65207ED09');
    $63:
      Result := DecodeHex('9C9B1372F8C640CF1C62F5D592DDB582');
    $64:
      Result := DecodeHex('03B302E85FF381B13B8DAA2A90FF5E61');
    $65:
      Result := DecodeHex('BCD7F9D32FACF847C0FB4D2F309ABDA6');
    $66:
      Result := DecodeHex('F55596E97FAF867FACB33AE69C8B6F93');
    $67:
      Result := DecodeHex('EE297093F94E445944171F8E86E170FC');
    $68:
      Result := DecodeHex('E434520CF088CFC8CD781B6CCF8C48C4');
    $69:
      Result := DecodeHex('C1BF66818EF953F2E1266B6F550CC9CD');
    $6A:
      Result := DecodeHex('560FFF8F3C9649144516F1BCBFCEA30C');
    $6B:
      Result := DecodeHex('2408DC753760A29F0554B5F243857399');
    $6C:
      Result := DecodeHex('DDD5B56A59C55AE83B9667C75C2AE2DC');
    $6D:
      Result := DecodeHex('AA686772E02D44D5CDBB6504BCD5BF4E');
    $6E:
      Result := DecodeHex('1F17F014E777A2FE4B136B56CD7EF7E9');
    $6F:
      Result := DecodeHex('C93548CF558D7503896B2EEB618CA902');
    $70:
      Result := DecodeHex('DE34C541E7CA86E8BEA7C31CECE4360F');
    $71:
      Result := DecodeHex('DDE5FF551B74F6F4E016D7AB22311B6A');
    $72:
      Result := DecodeHex('B0E93521333FD7BAB4762CCB4D8008D8');
    $73:
      Result := DecodeHex('381469C4C3F91B9633638E4D5F3DF029');
    $74:
      Result := DecodeHex('FA486AD98E6716EF6AB087F589457F2A');
    $75:
      Result := DecodeHex('321A091250148A3E963DEA025932E18F');
    $76:
      Result := DecodeHex('4B00BE29BCB02864CEFD43A96FD95CED');
    $77:
      Result := DecodeHex('577DC4FF0244E28091F4CA0A7569FDA8');
    $78:
      Result := DecodeHex('835336C61803E43E4EB30F6B6E799B7A');
    $79:
      Result := DecodeHex('5C9265FD7B596AA37A2F509D85E927F8');
    $7A:
      Result := DecodeHex('9A39FB89DF55B2601424CEA6D9650A9D');
    $7B:
      Result := DecodeHex('8B75BE91A8C75AD2D7A594A01CBB9591');
    $7C:
      Result := DecodeHex('95C21B8D05ACF5EC5AEE77812395C4D7');
    $7D:
      Result := DecodeHex('B9A461643633FA5D9488E2D3281E01A2');
    $7E:
      Result := DecodeHex('B8B084FB9F4CFAF730FE7325A2AB897D');
    $7F:
      Result := DecodeHex('5F8C179FC1B21DF1F6367A9CF7D3D47C');
  else
    raise EPSPPRX.Create('PSP: invalid KIRK key index');
  end;
end;

function TagKey(Tag: Cardinal; Legacy: Boolean; out Key, XorSeed: TBytes; out Code: Integer; out Scramble: Boolean): Boolean;
begin
  Result := True;
  Key := nil;
  XorSeed := nil;
  Scramble := False;
  if Legacy then
    case Tag of
      $00000000:
        begin
          Key := DecodeHex('BEF3217B1D5E9C29715E9C1C4546CB96E01B9B3C3DDE85EB22207F4AAA6E20C265320BD5670577554008083CF2551D98F3F6D85FC5B08EEE52814D94518627F8FABA052733E52084E94A152732AA194840AAA35965CFB32C6D4674F20556653A8FF8B021268DB1C55190C1644EC969D6F23570E809593A9D02714E6FCE46A9DC1B881684A597B0BAC625912472084CB3');
          Code := $42;
        end;
      $02000000:
        begin
          Key := DecodeHex('32A9FDCC766FC051CFCC6D041E82E1494C023B7D6558DA9D25988CCCB57DE9D1CBD8746887C97134FCB3ED725D36C8813AE361E159DB92FCECB10920E44CA9B16B69032FD836E287E98C2B3B84E70503830871F939DB39B037EA3B8905684DE7BD385C2A13C88DB07523B3152545BE4690FD0301A2870EA96AA6AB52807BBF8563CEE845D316D74D2D0DE3F556E43AAF');
          Code := $45;
        end;
      $03000000:
        begin
          Key := DecodeHex('CAF5C8A680C0676D3A4D4F926AA07C049702640858A7D44F875A68BDC201279B352AB6833C536B720CFA22E5B4064BC2AC1C9D457B41C5A8A262EA4F42D71506098D623014AB4FC45E71FF697D83D8D28B0BEDBEAE576E1E02C4E861067A36BE5E2B3F5458C03EDB752085BECC4D7E1E55EA6415B42578ECAD8C53C07F2CF770D0C3E849C57EA9EDA4B092F42AB05EE0');
          Code := $46;
        end;
      $4467415D:
        begin
          Key := DecodeHex('05E080EF9F68543ACD9CC943BE27771B3800B85C62FE2EDD2CF969F3C5940F1619005629C5103CBF6655CEF226C6A2CE6F8101B61E48E764BDDE340CB09CF298D704C53FF039FBC8D8B32102A236F96300483A9AE332CC6EFD0C128E231636B089E6E1AEEB0255741CC6A6E4B43EF2741358FAD7EB1619B057843212D297BCD2D8256464A5808332B18ADA43C92A124B');
          Code := $59;
        end;
      $207BBF2F:
        begin
          Key := DecodeHex('0008B533CD5F2FF31F88143C952A8A6ED5EFFE29E3EA941343D46BBD83C02108D379B3FA65E113E6D354A7F552298B10151E4B0ABADEEA61DF6575550153463BC3EC54AE0933426119FFC970ECE50A5B26F19D985F7A989D0E75BC5527BA6EC6E888E92DDA0066F7CBDC8203F2F569556212438ED3E38F2887216F659C2ED137B49E532F8E9992A4F75839ED2365E939');
          Code := $5A;
        end;
      $3ACE4DCE:
        begin
          Key := DecodeHex('697087671756BD3ADCB13AC27D5057AB407F6A06B9F9DE24E459F706B124F5DC5E3E79132D025903A2E1E7AAFAB2B9764003169ABA2F8287BB8FE219028A339E9A7E00D8F17A31EADE7106637CCA670BAF92518626353CEA8E8C442B5492598BCBE90246DA6CE14DBBD564E18ED8EC07F8E5FF99C1008876ED91B05334740484BCDB26B4BB48F9365821144692B49B74');
          Code := $5B;
        end;
      $07000000:
        begin
          Key := DecodeHex('AF00CB762FE61C11367EB2B7F9E88D6D6AF14BD57303E9D982D999750E2BF851AD03616335BC408E942C332FE9AA13F5E9FE2AD2873934040CB85BFC899D3412BB81A414E83AED254F0E507D57B7D143ADFD597B34BFFB4C3674D1C3DB21DAC1808C4DA35D232B964805423EFE9FCF095C3F88D4B59C0ED9E9F4AE00E96D88F05B8AA5624655A552B5411997AC9FB7F5');
          Code := $4A;
        end;
      $08000000:
        begin
          Key := DecodeHex('EF69CB1812898E15BB0EF9DE23FBB04C18EE87366E4A8D8656C7B5191D5516EE6C2DCBE760C647973F1495CE77F45629DE4A8203F19D0C2124EB29509FE6DF81009BC839918B0CB0C2F92DEFFC933AE1A8A4948B9DD01D490D406A68E4C7D4CEC9B7C89628DCAA1E840B17A4DC5D5D50CFC3A65D2DFA5D0EB519796EC7295ECE94DBACAADD0CF7452537A7623D56E6CC');
          Code := $4B;
        end;
      $C0CB167C:
        begin
          Key := DecodeHex('FA368EDA4774D95D7498C176AF7EE597BD09AB1CC6BA35988192D303CF05B20334E7822863F614E775276EB9C7AF8ABD29ECD31D6CA1A4EC87EC695F921E988521AEFC7C16DDE9BA0478A9E6FC02EE2E3D8ADF61640531DD49E197963B3F45C256841DF9C86BDA39F5FEE5B3A393C589BC8A5CFB12720B6CCBD30DE1A8B2D0984718D65F5723DCF06A160177683B5C0F');
          Code := $5D;
        end;
      $7F24BDCD:
        begin
          Key := DecodeHex('B482522AA5DD06871CEC884C8E7004D5D24D6372602F2EDDB5FDD5E37D6350E0AC695C297DF5617BB0124459CE25D913DDE86B2AE69495BC398A4A1F09596BC5F7B2CF529F08EE03217AA55C0F0964DBF3569A5E3366C5131D8DC4D97259A0CDB2139ED0DFD3ED7DBB874336887420CB3F4BC1BE110D9C7C40ED169919959065B3B15BC584E097E98B4383B455D2A2B8');
          Code := $60;
        end;
      $0B000000:
        begin
          Key := DecodeHex('BF3C60A5412448D7CC6457F60B06901F453EA74E92D151E58A5DB7E76E505A462210FB405033272C44DA96808E19479977EE8D272E065D7445FA48C1AF822583DA86DB5FCEC415CB2FC62425B1C32E6C9EE39B36C41FEBF71ACE511EF43605D7D8394DC313FB1874E14DC8E33CF018B14E8D01A20D77D8E690F320574163F9178FA6A46028DD2713644C9405124C2C0C');
          Code := $4E;
        end;
      $0C000000:
        begin
          Key := DecodeHex('2F10BF1A71D096D5B252C56F1F53F2D4D9CD25F003AF9AAFCF57CFE0C49454255E67037084C87B90E44E2D000D7A680B4FA43A9E81DA8FF58CAC26EC9DB4C93A37C071344D83F3B01144DC1031EA32A26BFAE5E2034B5945871C3AE4D1D9DA310370CD08DF2F9CFA251D895A34195C9BE566F322324A085FD51655699FBE452205D76D4FA1B8B8C400A613BC3BFCB777');
          Code := $4F;
        end;
      $0F000000:
        begin
          Key := DecodeHex('BCFE81A3C9D5B9998D0A566C959F3030CC4626795E4EB682AD51391AC42E180AB43161C48A0CC577C6165F322E94D102C48AA30AC60A942A2647036733B12DE50721EFD2901EC885BA64D1C81DCE8DC375A28B940346B80D373647E2DAFC74CD663D8E5822E8286D8B541E896DF53CF566DBBD0BAA86B2C44BBCEB2BF41F26FC05E7B8925269EEDCE542045E217FEB8B');
          Code := $52;
        end;
      $862648D1:
        begin
          Key := DecodeHex('98D6BF1124B3F9D7274952DD865B21166DC34A5017B2435847DAA0E5E7A173BB35DB15293AFD5C3705A970BBCAEF2B279107962EBB9907EAC8E65AB873F7CAC941E60E259E4AE7065D894452A555674653AF849A744102E11E03BAEECEB980ED725F31BC7F062158583031E806E7D0D23E93D8E6B47FD1D7C49650503B0BA5FD3DAE35468A9C48EB2D762D4231328B5A');
          Code := $52;
        end;
      $09000000:
        begin
          Key := DecodeHex('E8531B72C6313EFCA2A25BF872ACF03CABA7EE54CBBF59596B83B854131343BCCFF29E98B236CEF0F84CBA9831C971E9C85D37A0A02FE50826D40DAC01D6E457C7616EC58AB91AEFF4F8D9D108A7E95F079DF03E8C1A0CFA5CEA1EA9C582F4580203802CC3F6E67EBBBB6AFFD0D01021887A29D3D31200987BC859DC9257DC7FA65D3FDB87B723FCD38E692212E880B6');
          Code := $4C;
        end;
      $BB67C59F:
        begin
          Key := DecodeHex('C757A7943398D39F718350F8290B8B32DAB9BC2CC6B91829BA504C94D0E7DCF166390C64083D0BC9BA17ADF44BF8A06C677C76F75AA5D3A46A5C084A7170B26BFB388BFAB831DB3FF296718B4AED9BDB845B6251B481144C08F584F67047B430748EAA93BC79C5908DC86E240212052E2E8474C797D985A1DD3A2B7A6D5B83FE4D188F50134F4CEBD393190ED2DF96BA');
          Code := $5E;
        end;
      $0E000000:
        begin
          Key := DecodeHex('DE57B77717DD62EE7B78035D4486CA59208DF69328938121714EA786CA82241B58AE745F6C018D5632884D9A7243A22E84F40C82B906FCFC6AFB5B8AD79C9FBF010D8515BA5FED399383C34CAFDE3AEDBF68A71A778ABD8965415646D9DB3373816CE862969B29035AAEAF732053A040E84B6610996AB7E570DDE029282460EA30AE4220328D6F94715F9EA2D57F0C7C');
          Code := $51;
          Scramble := True;
        end;
    else
      Result := False;
    end
  else
    case Tag of
      $0B2B90F0:
        begin
          Key := DecodeHex('39F7DF19D710EA9F02DB3FB1109F266B');
          Code := $5C;
        end;
      $0B2B91F0:
        begin
          Key := DecodeHex('461DC9C21D44A668F20637BF62CD119E');
          Code := $5C;
        end;
      $0B2B92F0:
        begin
          Key := DecodeHex('110D1A4C8A1917DCD05A6547A5038522');
          Code := $5C;
        end;
      $495BE403:
        begin
          Key := DecodeHex('E4988E935B94AF19EA306CEA6F1F1159');
          Code := $5C;
        end;
      $0B2B05F0:
        begin
          Key := DecodeHex('C31A78C5F5BEC692F9EF94EA51E55711');
          Code := $5C;
        end;
      $0B2B06F0:
        begin
          Key := DecodeHex('9686DD7887A72BD9DDC66C4F89FBD4D7');
          Code := $5C;
        end;
      $0B2B08F0:
        begin
          Key := DecodeHex('27E131F5F79BE788D68D7C0D9973A18F');
          Code := $5C;
        end;
      $0B2B0AF0:
        begin
          Key := DecodeHex('6B3F9158ED40685493D6453F2CD42343');
          Code := $5C;
        end;
      $0B2B0BF0:
        begin
          Key := DecodeHex('F815CC79108916D6251100EB6BB113E2');
          Code := $5C;
        end;
      $0B2B11F0:
        begin
          Key := DecodeHex('1A26FD16320E71D0DCD13CE553D54499');
          Code := $5C;
        end;
      $0B2B1EF0:
        begin
          Key := DecodeHex('20DCEFB80A8D432768B9F91138948428');
          Code := $5C;
        end;
      $0B2B0CF0:
        begin
          Key := DecodeHex('2FB504EFCBC8EC823126F70A186FAFC7');
          Code := $5C;
        end;
      $0B2B12F0:
        begin
          Key := DecodeHex('E5B6DC8394D176EA992D2216E803A203');
          Code := $5C;
        end;
      $0B2B1FF0:
        begin
          Key := DecodeHex('EF007932CE707121060CA3A07BA89653');
          Code := $5C;
        end;
      $0B2B80F0:
        begin
          Key := DecodeHex('57B4A65C752DB94DE167E331BF4D70F8');
          Code := $5C;
        end;
      $0B2B81F0:
        begin
          Key := DecodeHex('29200B22CF1FD75064A75020EC226FB8');
          Code := $5C;
        end;
      $0B2B82F0:
        begin
          Key := DecodeHex('04B69F9239EBE8B2CB3829F64177FFAD');
          Code := $5C;
        end;
      $4C9494F0:
        begin
          Key := DecodeHex('76F26C0ACA3ABA4EAC76D240F5C3BFF9');
          Code := $43;
        end;
      $4C9495F0:
        begin
          Key := DecodeHex('7A3E5575B96AFC4F3EE3DFB36CE82A82');
          Code := $43;
        end;
      $4C9490F0:
        begin
          Key := DecodeHex('FA790936E619E8A4A94137188102E9B3');
          Code := $43;
        end;
      $4C9491F0:
        begin
          Key := DecodeHex('85931FED2C4DA453599C3F16F350DE46');
          Code := $43;
        end;
      $4C9493F0:
        begin
          Key := DecodeHex('C8A07098AEE62B80D791E6CA4CA9784E');
          Code := $43;
        end;
      $4C9497F0:
        begin
          Key := DecodeHex('BFF834028447BD871C52032379BB5981');
          Code := $43;
        end;
      $4C9492F0:
        begin
          Key := DecodeHex('D283CC63BB1015E77BC06DEE349E4AFA');
          Code := $43;
        end;
      $4C9496F0:
        begin
          Key := DecodeHex('EBD91E053CAEAB62E3B71F37E5CD68C3');
          Code := $43;
        end;
      $457B90F0:
        begin
          Key := DecodeHex('BA7661478B55A8728915796DD72F780E');
          Code := $5B;
        end;
      $457B91F0:
        begin
          Key := DecodeHex('C59C779C4101E48579C87163A57D4FFB');
          Code := $5B;
        end;
      $457B92F0:
        begin
          Key := DecodeHex('928CA412D65C55315B94239B62B3DB47');
          Code := $5B;
        end;
      $457B93F0:
        begin
          Key := DecodeHex('88AF18E9C3AA6B56F7C5A8BF1A84E9F3');
          Code := $5B;
        end;
      $380290F0:
        begin
          Key := DecodeHex('F94A6B96793FEE0A04C88D7E5F383ACF');
          Code := $5A;
        end;
      $380291F0:
        begin
          Key := DecodeHex('86A07D4DB36BA2FDF41585702D6A0D3A');
          Code := $5A;
        end;
      $380292F0:
        begin
          Key := DecodeHex('D1B0AEC324361349D649D788EAA49986');
          Code := $5A;
        end;
      $380293F0:
        begin
          Key := DecodeHex('CB93123831C02D2E7A185CAC9293AB32');
          Code := $5A;
        end;
      $4C948CF0:
        begin
          Key := DecodeHex('017BF0E9BE9ADD5437EA0EC4D64D8E9E');
          Code := $43;
        end;
      $4C948DF0:
        begin
          Key := DecodeHex('9843FF8568B2DB3BD422D04FAB5F0A31');
          Code := $43;
        end;
      $4C948BF0:
        begin
          Key := DecodeHex('91F2029E633230A91DDA0BA8B741A3CC');
          Code := $43;
        end;
      $4C948AF0:
        begin
          Key := DecodeHex('07E308647F60A3366A762144C9D70683');
          Code := $43;
        end;
      $4C9487F0:
        begin
          Key := DecodeHex('81D1128935C8EA8BE0022D2D6A1867B8');
          Code := $43;
        end;
      $457B83F0:
        begin
          Key := DecodeHex('771C065F53EC3FFC22CE5A27FF78A848');
          Code := $5B;
        end;
      $4C9486F0:
        begin
          Key := DecodeHex('8DDBDC5CF2702B40B23D0009617C1060');
          Code := $43;
        end;
      $457B82F0:
        begin
          Key := DecodeHex('873721CC65AEAA5F40F66F2A86C7A1C8');
          Code := $5B;
        end;
      $457B81F0:
        begin
          Key := DecodeHex('AAA1B57C935A95BDEF6916FC2B9231DD');
          Code := $5B;
        end;
      $4C9485F0:
        begin
          Key := DecodeHex('238D3DAE4150A0FAF32F32CEC727CD50');
          Code := $43;
        end;
      $457B80F0:
        begin
          Key := DecodeHex('D43518022968FBA06AA9A5ED78FD2E9D');
          Code := $5B;
        end;
      $4C9484F0:
        begin
          Key := DecodeHex('36B0DCFC592A951D802D803FCD30A01B');
          Code := $43;
        end;
      $457B28F0:
        begin
          Key := DecodeHex('B1B37F76C3FB88E6F860D3353CA34EF3');
          Code := $5B;
        end;
      $457B0CF0:
        begin
          Key := DecodeHex('AC34BAB1978DAE6FBAE8B1D6DFDFF1A2');
          Code := $5B;
        end;
      $380228F0:
        begin
          Key := DecodeHex('F28F75A73191CE9E75BD2726B4B40C32');
          Code := $5A;
        end;
      $4C942AF0:
        begin
          Key := DecodeHex('418A354F693ADF04FD3946A25C2DF221');
          Code := $43;
        end;
      $4C9428F0:
        begin
          Key := DecodeHex('F1BC1707AEB7C830D8349D406A8EDF4E');
          Code := $43;
        end;
      $4C941DF0:
        begin
          Key := DecodeHex('1D13E95004733DD2E1DAB9C1E67B25A7');
          Code := $43;
        end;
      $4C941CF0:
        begin
          Key := DecodeHex('D6BDCE1E12AF9AE66930DEDA88B8FFFB');
          Code := $43;
        end;
      $4C9422F0:
        begin
          Key := DecodeHex('E145932C53E2AB066FB68F0B6691E71E');
          Code := $43;
        end;
      $4C941EF0:
        begin
          Key := DecodeHex('E35239973B84411CC323F1B8A9094BF0');
          Code := $43;
        end;
      $4C9429F0:
        begin
          Key := DecodeHex('6D72A4BA7FBFD1F1A9F3BB071BC0B366');
          Code := $43;
        end;
      $4C941BF0:
        begin
          Key := DecodeHex('AB1A7443F74FE5FF04A5FC3BECD4F8F0');
          Code := $43;
        end;
      $4C941AF0:
        begin
          Key := DecodeHex('9FFD4C2820B13E76364AAB1C54BC3BDC');
          Code := $43;
        end;
      $457B0BF0:
        begin
          Key := DecodeHex('7B9472274CCC543BAEDF4637AC014D87');
          Code := $5B;
        end;
      $4C9419F0:
        begin
          Key := DecodeHex('582A4C69197B833DD26161FE14EEAA11');
          Code := $43;
        end;
      $4C9418F0:
        begin
          Key := DecodeHex('2E8E97A28542707318DAA08AF862A2B0');
          Code := $43;
        end;
      $457B1EF0:
        begin
          Key := DecodeHex('A35D51E656C801CAE377BFCDFF24DA4D');
          Code := $5B;
        end;
      $4C941FF0:
        begin
          Key := DecodeHex('2C8EAF1DFF79731AAD96AB09EA35598B');
          Code := $43;
        end;
      $4C9417F0:
        begin
          Key := DecodeHex('BAE2A31207FF041B64A51185F72F995B');
          Code := $43;
        end;
      $4C9416F0:
        begin
          Key := DecodeHex('EB1B530B624932581F830AF4993D75D0');
          Code := $43;
        end;
      $4C9414F0:
        begin
          Key := DecodeHex('45EF5C5DED81998412948FABE8056D7D');
          Code := $43;
        end;
      $4C9415F0:
        begin
          Key := DecodeHex('701B082522A14D3B6921F9710AA841A9');
          Code := $43;
        end;
      $4C9412F0:
        begin
          Key := DecodeHex('26380AACA5D874D132B72ABF799E6DDB');
          Code := $43;
        end;
      $4C9413F0:
        begin
          Key := DecodeHex('53E7ABB9C64A4B779217B5740ADAA9EA');
          Code := $43;
        end;
      $457B10F0:
        begin
          Key := DecodeHex('7110F0A41614D59312FF7496DF1FDA89');
          Code := $5B;
        end;
      $4C940DF0:
        begin
          Key := DecodeHex('3C2B51D42D8547DA2DCA18DFFE5409ED');
          Code := $43;
        end;
      $4C9410F0:
        begin
          Key := DecodeHex('311F98D57B58954532AB3AE389324B34');
          Code := $43;
        end;
      $4C940BF0:
        begin
          Key := DecodeHex('3B9B1A56218014ED8E8B0842FA2CDC3A');
          Code := $43;
        end;
      $457B0AF0:
        begin
          Key := DecodeHex('E8BE2F06B1052AB9181803E3EB647D26');
          Code := $5B;
        end;
      $38020AF0:
        begin
          Key := DecodeHex('AB8225D7436F6CC195C5F7F063733FE7');
          Code := $5A;
        end;
      $4C940AF0:
        begin
          Key := DecodeHex('A8B14777DC496A6F384C4D96BD49EC9B');
          Code := $43;
        end;
      $4C940CF0:
        begin
          Key := DecodeHex('EC3BD2C0FAC1EEB99ABCFFA389F2601F');
          Code := $43;
        end;
      $CFEF09F0:
        begin
          Key := DecodeHex('A241E839665BFABB1B2D6E0E33E5D73F');
          Code := $62;
        end;
      $457B08F0:
        begin
          Key := DecodeHex('A4608FABABDEA5655D433AD15EC3FFEA');
          Code := $5B;
        end;
      $380208F0:
        begin
          Key := DecodeHex('E75C857A59B4E31DD09ECEC2D6D4BD2B');
          Code := $5A;
        end;
      $CFEF08F0:
        begin
          Key := DecodeHex('2E00F6F752CF955AA126B4849B58762F');
          Code := $62;
        end;
      $CFEF07F0:
        begin
          Key := DecodeHex('7BA1E25A91B9D31377654AB7C28A10AF');
          Code := $62;
        end;
      $CFEF06F0:
        begin
          Key := DecodeHex('9F671A7A22F3590BAA6DA4C68BD00377');
          Code := $62;
        end;
      $457B06F0:
        begin
          Key := DecodeHex('15076326DBE2693456082A934E4B8AB2');
          Code := $5B;
        end;
      $380206F0:
        begin
          Key := DecodeHex('563B69F729882F4CDBD5DE80C65CC873');
          Code := $5A;
        end;
      $CFEF05F0:
        begin
          Key := DecodeHex('CAFBBFC750EAB4408E445C6353CE80B1');
          Code := $62;
        end;
      $457B05F0:
        begin
          Key := DecodeHex('409BC69BA9FB847F7221D23696550974');
          Code := $5B;
        end;
      $380205F0:
        begin
          Key := DecodeHex('03A7CC4A5B91C207FFFC26251E424BB5');
          Code := $5A;
        end;
      $16D59E03:
        begin
          Key := DecodeHex('C32489D38087B24E4CD749E49D1D34D1');
          Code := $62;
        end;
      $76202403:
        begin
          Key := DecodeHex('F3AC6E7C040A23E70D33D82473392B4A');
          Code := $5B;
        end;
      $0F037303:
        begin
          Key := DecodeHex('72B439FF349BAE8230344A1DA2D8B43C');
          Code := $5A;
        end;
      $4C940FF0:
        begin
          Key := DecodeHex('8002C0BF000AC0BF4003C0BF40000000');
          Code := $43;
        end;
      $4467415D:
        begin
          Key := DecodeHex('660FCB3B3075E3100A9565C73C938722');
          Code := $59;
        end;
      $00000000:
        begin
          Key := DecodeHex('6A1971F318DED3A26D3BDEC7BE98E24C');
          Code := $42;
        end;
      $01000000:
        begin
          Key := DecodeHex('50CC03AC3F531AFA0AA4342386617F97');
          Code := $43;
        end;
      $2E5E0AF0:
        begin
          Key := DecodeHex('ACD76D90333738923141D636AF9F1715');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E10F0:
        begin
          Key := DecodeHex('9D5C5BAF8CD8697E519F7096E6D5C4E8');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E11F0:
        begin
          Key := DecodeHex('75EBE843F4878FD0147F7E39ADAF049D');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E12F0:
        begin
          Key := DecodeHex('8A7BC9D6525888EA518360CA1679E207');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E13F0:
        begin
          Key := DecodeHex('FFA468C331CAB74CF123FF01653D2636');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E80F0:
        begin
          Key := DecodeHex('0F74AF4375CDDA398156D9613E16C892');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2E5E90F0:
        begin
          Key := DecodeHex('67E48F4C08A07DB15F51A77298A82D7E');
          Code := $48;
          XorSeed := DecodeHex('69BA5534F0C0D671E31FDB97E07CD22A');
        end;
      $2FD30BF0:
        begin
          Key := DecodeHex('D85879F9A422AF8690ACDA45CE60403F');
          Code := $47;
        end;
      $D91605F0:
        begin
          Key := DecodeHex('B88C458BB6E76EB85159A6537C5E8631');
          Code := $5D;
        end;
      $D91606F0:
        begin
          Key := DecodeHex('ED10E036C4FE83F375705EF6A44005F7');
          Code := $5D;
        end;
      $D91608F0:
        begin
          Key := DecodeHex('5C770CBBB4C24FA27E3B4EB4B4C870AF');
          Code := $5D;
        end;
      $D91609F0:
        begin
          Key := DecodeHex('D036127580562043C430943E1C75D1BF');
          Code := $5D;
        end;
      $D9160AF0:
        begin
          Key := DecodeHex('10A9AC16AE19C07E3B607786016FF263');
          Code := $5D;
        end;
      $D9160BF0:
        begin
          Key := DecodeHex('8383F13753D0BEFC8DA73252460AC2C2');
          Code := $5D;
        end;
      $D91611F0:
        begin
          Key := DecodeHex('61B0C0587157D9FA74670E5C7E6E95B9');
          Code := $5D;
        end;
      $D91612F0:
        begin
          Key := DecodeHex('9E20E1CDD788DEC0319B10AFC5B87323');
          Code := $5D;
        end;
      $D91613F0:
        begin
          Key := DecodeHex('EBFF40D8B41AE166913B8F64B6FCB712');
          Code := $5D;
        end;
      $D91614F0:
        begin
          Key := DecodeHex('FDF7B73C9FD1339511B8B5BB54237385');
          Code := $5D;
        end;
      $D91615F0:
        begin
          Key := DecodeHex('C803E34450F1E72A6A0DC361B68E5F51');
          Code := $5D;
        end;
      $D91616F0:
        begin
          Key := DecodeHex('5303B86A101998491CAF30E4251B6B28');
          Code := $5D;
        end;
      $D91617F0:
        begin
          Key := DecodeHex('02FA487375AFAE0A67892B954B0987A3');
          Code := $5D;
        end;
      $D91618F0:
        begin
          Key := DecodeHex('96967CC3F712DA621BF69A9A4444BC48');
          Code := $5D;
        end;
      $D91619F0:
        begin
          Key := DecodeHex('E032A7086B2B292CD14D5BEEA8C8B4E9');
          Code := $5D;
        end;
      $D9161AF0:
        begin
          Key := DecodeHex('27E5A74952E194673566910CE89A2524');
          Code := $5D;
        end;
      $D91620F0:
        begin
          Key := DecodeHex('521CB45F403B9ADDACFCEA92FDDDF590');
          Code := $5D;
        end;
      $D91621F0:
        begin
          Key := DecodeHex('D1912EA621142962F6EDAECBDDA3BAFE');
          Code := $5D;
        end;
      $D91622F0:
        begin
          Key := DecodeHex('595D784D21B201176C9AB51BDAB7F9E6');
          Code := $5D;
        end;
      $D91623F0:
        begin
          Key := DecodeHex('AA45EB4F62FBD10D71D562D2F5BFA52F');
          Code := $5D;
        end;
      $D91624F0:
        begin
          Key := DecodeHex('61B726AF8BF14158836AC49212CBB1E9');
          Code := $5D;
        end;
      $D91628F0:
        begin
          Key := DecodeHex('49A4FC66DCE76221DB18A750D6A8C1B6');
          Code := $5D;
        end;
      $D91680F0:
        begin
          Key := DecodeHex('2C229B123674116749D1D18892F6A1D8');
          Code := $5D;
        end;
      $D91681F0:
        begin
          Key := DecodeHex('52B6366C8C467F7ACC116299C199BE98');
          Code := $5D;
        end;
      $D82310F0:
        begin
          Key := DecodeHex('9D09FD20F38F10690DB26F00CCC5512E');
          Code := $51;
        end;
      $D8231EF0:
        begin
          Key := DecodeHex('4F445C62B353C430FC3AA45BECFE51EA');
          Code := $51;
        end;
      $D82328F0:
        begin
          Key := DecodeHex('5DAA72F226604D1CE72DC8A32F79C554');
          Code := $51;
        end;
      $279D08F0:
        begin
          Key := DecodeHex('C7277285ABA7F7F04CC186CCE37F17CA');
          Code := $61;
        end;
      $279D06F0:
        begin
          Key := DecodeHex('76409E08DB9B3BA1478A968EF3F76292');
          Code := $61;
        end;
      $279D05F0:
        begin
          Key := DecodeHex('23DC3BB5A982D6EA63A36E2B2BE9E154');
          Code := $61;
        end;
      $D66DF703:
        begin
          Key := DecodeHex('224357682F41CE654CA37CC6C4ACF360');
          Code := $61;
        end;
      $279D10F0:
        begin
          Key := DecodeHex('12570D8A166D8706037DC88B62A332A9');
          Code := $61;
        end;
      $3C2A08F0:
        begin
          Key := DecodeHex('1E2E3849DAD41608272EF3BC37758093');
          Code := $67;
        end;
      $ADF305F0:
        begin
          Key := DecodeHex('1299705E24076CD02D06FE7EB30C1126');
          Code := $60;
        end;
      $ADF306F0:
        begin
          Key := DecodeHex('4705D5E3561E819B092F06DB6B1292E0');
          Code := $60;
        end;
      $ADF308F0:
        begin
          Key := DecodeHex('F662396E26224DCA026416997B9AE7B8');
          Code := $60;
        end;
      $8004FD03:
        begin
          Key := DecodeHex('F4AEF4E186DDD29C7CC542A695A08388');
          Code := $5D;
        end;
      $0A35EA03:
        begin
          Key := DecodeHex('F948380C9688A7744F65A054C276D9B8');
          Code := $5E;
        end;
      $7B0505F0:
        begin
          Key := DecodeHex('2D86773A56A44FDD3C167193AA8E1143');
          Code := $5E;
        end;
      $7B0506F0:
        begin
          Key := DecodeHex('781AD28724BDA296183F893672909285');
          Code := $5E;
        end;
      $7B0508F0:
        begin
          Key := DecodeHex('C97D3E0A54816EC7137499746218E7DD');
          Code := $5E;
        end;
      $380210F0:
        begin
          Key := DecodeHex('322CFA75E47E93EB9F22808557089848');
          Code := $5A;
        end;
      $380280F0:
        begin
          Key := DecodeHex('970912D3DB02BDD8E77451FEF0EA6C5C');
          Code := $5A;
        end;
      $380283F0:
        begin
          Key := DecodeHex('34200C8EA1867984AF13AE34776FEA89');
          Code := $5A;
        end;
      $407810F0:
        begin
          Key := DecodeHex('AFADCAF1955991EC1B27D04E8AF33DE7');
          Code := $6A;
        end;
      $E92410F0:
        begin
          Key := DecodeHex('36EF824E74FB175B141405F3B38A7618');
          Code := $40;
        end;
      $692810F0:
        begin
          Key := DecodeHex('21525D76F6810F152F4A408963A01055');
          Code := $40;
        end;
      $2FD313F0:
        begin
          Key := DecodeHex('B024C81643E8F01C8C3067733E9635EF');
          Code := $47;
          XorSeed := DecodeHex('A91EDD7B09BB22B59DA33069136E0ED8');
        end;
      $2FD312F0:
        begin
          Key := DecodeHex('C5FB6903207ACFBA2C90F8B84DD2F1DE');
          Code := $47;
          XorSeed := DecodeHex('A91EDD7B09BB22B59DA33069136E0ED8');
        end;
      $2FD311F0:
        begin
          Key := DecodeHex('3A6B489686A5C880696CE64BF6041744');
          Code := $47;
          XorSeed := DecodeHex('A91EDD7B09BB22B59DA33069136E0ED8');
        end;
      $89742B04:
        begin
          Key := DecodeHex('D7EBC9247E233D8946E72E47ADDB0D09');
          Code := $65;
          XorSeed := DecodeHex('FF5EF1E9B1C93EC5DBE06782953A8EA5');
        end;
    else
      Result := False;
    end;
end;

function LE32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  if (Offset < 0) or (Offset > Length(Data) - 4) then
    raise EPSPPRX.Create('PSP: truncated PRX word');
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
    (Cardinal(Data[Offset + 2]) shl 16) or (Cardinal(Data[Offset + 3]) shl 24);
end;

procedure Put32(var Data: TBytes; Offset: Integer; Value: Cardinal);
begin
  for var I := 0 to 3 do
    Data[Offset + I] := Byte((Value shr (I * 8)) and $FF);
end;

function EqualBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function SHA1(const Data: TBytes): TBytes;
begin
  var Hash := THashSHA1.Create;
  Hash.Update(Data);
  Result := Hash.HashAsBytes;
end;

function Kirk7(const Data: TBytes; Code: Integer): TBytes;
begin
  Result := PSPAESDecrypt(Data, KirkKey(Code));
end;

function ExpandSeed(const Key: TBytes; Code: Integer): TBytes;
begin
  SetLength(Result, $90);
  for var Block := 0 to 8 do
  begin
    Move(Key[0], Result[Block * 16], 16);
    Result[Block * 16] := Block;
  end;
  Result := Kirk7(Result, Code);
end;

function Kirk1(const Data: TBytes): TBytes;
begin
  if (Length(Data) < $90) or (LE32(Data, $60) <> 1) then
    raise EPSPPRX.Create('PSP: invalid KIRK1 header');
  if Data[$64] <> 0 then
    raise EPSPPRX.Create('PSP: KIRK ECDSA authentication is not implemented');
  var Size := Int64(LE32(Data, $70));
  var Offset := Int64(LE32(Data, $74));
  var Aligned := (Size + 15) and not Int64(15);
  if (Size = 0) or (Size > 64 * 1024 * 1024) or ($90 + Offset + Aligned > Length(Data)) then
    raise EPSPPRX.Create('PSP: invalid KIRK1 data extent');
  var Keys := PSPAESDecrypt(Copy(Data, 0, 32), DecodeHex('98C940975C1D10E87FE60EA3FD03A8BA'));
  var AES: TPSPAES;
  AES.Init(Copy(Keys, 16, 16));
  if not EqualBytes(AES.CMAC(Copy(Data, $60, $30)), Copy(Data, $20, 16)) then
    raise EPSPPRX.Create('PSP: KIRK1 header CMAC mismatch');
  if not EqualBytes(AES.CMAC(Copy(Data, $60, $30 + Offset + Aligned)), Copy(Data, $30, 16)) then
    raise EPSPPRX.Create('PSP: KIRK1 data CMAC mismatch');
  Result := PSPAESDecrypt(Copy(Data, $90 + Offset, Aligned), Copy(Keys, 0, 16));
  SetLength(Result, Size);
end;

function LegacyHeader(const Data, Seed: TBytes; Code: Integer; Variant: Integer; out Block: TBytes): Boolean;
begin
  var Layout: TBytes;
  SetLength(Layout, $150);
  Move(Data[$D0], Layout[0], 4);
  Move(Data[$D4], Layout[4], $14);
  Move(Data[$E8], Layout[$18], $28);
  Move(Data[$110], Layout[$40], $40);
  Move(Data[$80], Layout[$80], $50);
  Move(Data[0], Layout[$D0], $80);
  if Variant = 1 then
  begin
    var Decoded := Kirk7(Copy(Layout, $10, $A0), Code);
    Move(Decoded[0], Layout[$10], $A0);
  end;
  var Digest := SHA1(Copy(Seed, 0, $14) + Copy(Layout, $18, $28) +
    Copy(Layout, $40, $90) + Copy(Layout, $D0, $80));
  Result := EqualBytes(Digest, Copy(Layout, 4, $14));
  if not Result then
    Exit;
  Block := Copy(Layout, $40, $90);
  var Header := Copy(Block, 0, $70);
  for var I := 0 to $6F do
    Header[I] := Header[I] xor Seed[$14 + I];
  Header := Kirk7(Header, Code);
  for var I := 0 to $6F do
    Block[I] := Header[I] xor Seed[$20 + I];
end;

function ModernHeader(const Data, Seed, XorSeed: TBytes; Code, Variant: Integer; out Block: TBytes): Boolean;
begin
  var Layout: TBytes;
  SetLength(Layout, $150);
  Move(Data[$D0], Layout[0], 4);
  Move(Data[$140], Layout[$5C], 16);
  Move(Data[$12C], Layout[$6C], $14);
  Move(Data[$80], Layout[$80], $30);
  Move(Data[$C0], Layout[$B0], $10);
  Move(Data[$B0], Layout[$C0], 16);
  Move(Data[0], Layout[$D0], $80);
  if Variant = 5 then
  begin
    var Extra := XorSeed;
    if Data[$7C] = 23 then
      Extra := DecodeHex('847BF5FEE84DAD7AB506280E09FA81E1');
    var Work := Copy(Layout, $80, $40) + Copy(Layout, $6C, $10);
    if Length(Extra) = 16 then
      for var I := 0 to High(Work) do
        Work[I] := Work[I] xor Extra[I mod 16];
    Work := Kirk7(Work, Code);
    Move(Work[0], Layout[$80], $40);
    Move(Work[$40], Layout[$6C], $10);
    if Length(Extra) = 16 then
      for var I := $5C to $BB do
        Layout[I] := Layout[I] xor Extra[(I - $5C) mod 16];
  end;
  var Decoded := Kirk7(Copy(Layout, $5C, $60), Code);
  Move(Decoded[0], Layout[$5C], $60);
  var Digest := SHA1(Copy(Layout, 0, 4) + Copy(Seed, 0, 16) + Copy(Layout, 4, $58) +
    Copy(Layout, $5C, 16) + Copy(Layout, $80, $40) + Copy(Layout, $C0, 16) + Copy(Layout, $D0, $80));
  Result := EqualBytes(Digest, Copy(Layout, $6C, $14));
  if not Result then
    Exit;
  SetLength(Block, $90);
  FillChar(Block[0], Length(Block), 0);
  Move(Layout[$C0], Block[$70], 16);
  var Header := Copy(Layout, $80, $40);
  for var I := 0 to $3F do
    Header[I] := Header[I] xor Seed[$10 + I];
  Header := Kirk7(Header, Code);
  for var I := 0 to $3F do
    Block[I] := Header[I] xor Seed[$50 + I];
  Put32(Block, $60, 1);
end;

function DecryptPSPPRX(const Data: TBytes): TBytes;
begin
  if (Length(Data) >= 8) and (LE32(Data, 0) = $4543537E) then
  begin
    var HeaderSize := LE32(Data, 4);
    if (HeaderSize < 8) or (HeaderSize > Cardinal(Length(Data) - 4)) then
      raise EPSPPRX.Create('PSP: invalid SCE wrapper extent');
    var Magic := LE32(Data, HeaderSize);
    if (Magic <> $5053507E) and (Magic <> $464C457F) then
      raise EPSPPRX.Create('PSP: invalid SCE module payload');
    Exit(DecryptPSPPRX(Copy(Data, HeaderSize, Length(Data) - Integer(HeaderSize))));
  end;
  if (Length(Data) < 4) or (LE32(Data, 0) <> $5053507E) then
    Exit(Copy(Data));
  if Length(Data) < $150 then
    raise EPSPPRX.Create('PSP: truncated encrypted PRX');
  var Tag := LE32(Data, $D0);
  var Size := LE32(Data, $B0);
  if (Size = 0) or (Size > 64 * 1024 * 1024) then
    raise EPSPPRX.Create('PSP: invalid PRX output size');
  var Key, XorSeed, Seed, Header: TBytes;
  var Code: Integer;
  var Scramble: Boolean;
  var Found := False;
  if TagKey(Tag, True, Key, XorSeed, Code, Scramble) then
  begin
    Seed := Key;
    if Scramble then
      Seed := Kirk7(Seed, Code);
    Found := LegacyHeader(Data, Seed, Code, 0, Header) or LegacyHeader(Data, Seed, Code, 1, Header);
  end;
  if not Found and TagKey(Tag, False, Key, XorSeed, Code, Scramble) then
  begin
    Seed := ExpandSeed(Key, Code);
    Found := ModernHeader(Data, Seed, XorSeed, Code, 2, Header) or ModernHeader(Data, Seed, XorSeed, Code, 5, Header);
  end;
  if not Found then
    raise EPSPPRX.CreateFmt('PSP: PRX tag %.8x is unknown or header SHA-1 is invalid', [Tag]);
  // KIRK starts at original offset 0x40; its 0x90 header is followed by the
  // original 0x80-byte PSP header, then encrypted payload at original 0x150.
  var Wrapped := Header + Copy(Data, 0, $80) + Copy(Data, $150, Length(Data) - $150);
  Result := Kirk1(Wrapped);
  if Cardinal(Length(Result)) <> Size then
    raise EPSPPRX.Create('PSP: PRX/KIRK size mismatch');
  if (Length(Result) >= 2) and (Result[0] = $1F) and (Result[1] = $8B) then
  begin
    var Expected := LE32(Data, $28);
    if (Expected < 52) or (Expected > 64 * 1024 * 1024) then
      raise EPSPPRX.Create('PSP: invalid decompressed ELF size');
    var Input := TBytesStream.Create(Result);
    try
      var Decoder := TZDecompressionStream.Create(Input, 15 + 16);
      try
        SetLength(Result, Expected);
        Decoder.ReadBuffer(Result[0], Length(Result));
        var Extra: Byte;
        if Decoder.Read(Extra, 1) <> 0 then
          raise EPSPPRX.Create('PSP: decompressed module exceeds ELF size');
      finally
        Decoder.Free;
      end;
    finally
      Input.Free;
    end;
  end;
  if (Length(Result) < 52) or (LE32(Result, 0) <> $464C457F) then
    raise EPSPPRX.Create('PSP: decrypted module is not an ELF (unsupported compression)');
end;

end.


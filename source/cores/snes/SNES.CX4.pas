unit SNES.CX4;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TCx4Read = function(Address: Cardinal): Byte of object;

  TCx4Write = procedure(Address: Cardinal; Value: Byte) of object;

  TCx4Memory = (Unmapped, ROM, SRAM, Registers);

  TCx4Map = function(Address: Cardinal): TCx4Memory of object;

  TCx4Bus = packed record
    Enabled, Reading, Writing: Boolean;
    DelayCycles: Byte;
    Address: Cardinal;
  end;

  TCx4Dma = packed record
    Source, Dest: Cardinal;
    Length: Word;
    Pos: Cardinal;
    Enabled: Boolean;
  end;

  TCx4Cache = packed record
    Enabled, Preload: Boolean;
    Page: Byte;
    Lock: array[0..1] of Boolean;
    Address: array[0..1] of Cardinal;
    Base: Cardinal;
    ProgramBank: Word;
    ProgramCounter: Byte;
    Pos: Word;
  end;

  TCx4Suspend = packed record
    Duration: Cardinal;
    Enabled: Boolean;
  end;

  TCx4State = packed record
    CycleCount: UInt64;
    PB: Word;
    PC: Byte;
    A: Cardinal;
    P: Word;
    SP: Byte;
    Stack: array[0..7] of Cardinal;
    Mult: UInt64;
    RomBuffer: Cardinal;
    RamBuffer: array[0..2] of Byte;
    MemoryDataReg, MemoryAddressReg, DataPointerReg: Cardinal;
    Regs: array[0..15] of Cardinal;
    Negative, Zero, Carry, Overflow, IrqFlag: Boolean;
    Stopped, Locked, IrqDisabled, SingleRom: Boolean;
    RomAccessDelay, RamAccessDelay: Byte;
    Bus: TCx4Bus;
    Dma: TCx4Dma;
    Cache: TCx4Cache;
    Suspend: TCx4Suspend;
    Vectors: array[0..31] of Byte;
  end;

  TSnesCX4 = class
  private
    FRead: TCx4Read;
    FWrite: TCx4Write;
    FMap: TCx4Map;
    FTarget: UInt64;
    FIRQ: Boolean;
    procedure Tick(Cycles: UInt64);
    procedure Stop;
    function AccessDelay(Address: Cardinal): Byte;
    function ProcessCache(Target: UInt64): Boolean;
    procedure ProcessDMA(Target: UInt64);
    procedure SwitchCachePage;
    function Source(Index: Byte): Cardinal;
    procedure StoreRegister(Index: Byte; Value: Cardinal);
    procedure SetA(Value: Cardinal);
    procedure SetNZ;
    function AddValues(A, B: Cardinal): Cardinal;
    function Subtract(A, B: Cardinal): Cardinal;
    procedure Branch(Take: Boolean; FarBank, Dest: Byte; Call: Boolean);
  public
    State: TCx4State;
    ProgramRAM: array[0..1, 0..255] of Word;
    DataRAM: array[0..$BFF] of Byte;
    constructor Create(ReadBus: TCx4Read; WriteBus: TCx4Write; MapBus: TCx4Map);
    procedure Reset;
    procedure Execute(Opcode: Word);
    procedure RunUntil(Target: UInt64);
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure SerializeState(Archive: TStateArchive);
    property IRQ: Boolean read FIRQ;
  end;

implementation

const
  Cx4Data: array[0..1023] of Cardinal = (
    $FFFFFF, $800000, $400000, $2AAAAA, $200000, $199999, $155555, $124924,
    $100000, $0E38E3, $0CCCCC, $0BA2E8, $0AAAAA, $09D89D, $092492, $088888,
    $080000, $078787, $071C71, $06BCA1, $066666, $061861, $05D174, $0590B2,
    $055555, $051EB8, $04EC4E, $04BDA1, $049249, $0469EE, $044444, $042108,
    $040000, $03E0F8, $03C3C3, $03A83A, $038E38, $03759F, $035E50, $034834,
    $033333, $031F38, $030C30, $02FA0B, $02E8BA, $02D82D, $02C859, $02B931,
    $02AAAA, $029CBC, $028F5C, $028282, $027627, $026A43, $025ED0, $0253C8,
    $024924, $023EE0, $0234F7, $022B63, $022222, $02192E, $021084, $020820,
    $020000, $01F81F, $01F07C, $01E913, $01E1E1, $01DAE6, $01D41D, $01CD85,
    $01C71C, $01C0E0, $01BACF, $01B4E8, $01AF28, $01A98E, $01A41A, $019EC8,
    $019999, $01948B, $018F9C, $018ACB, $018618, $018181, $017D05, $0178A4,
    $01745D, $01702E, $016C16, $016816, $01642C, $016058, $015C98, $0158ED,
    $015555, $0151D0, $014E5E, $014AFD, $0147AE, $01446F, $014141, $013E22,
    $013B13, $013813, $013521, $01323E, $012F68, $012C9F, $0129E4, $012735,
    $012492, $0121FB, $011F70, $011CF0, $011A7B, $011811, $0115B1, $01135C,
    $011111, $010ECF, $010C97, $010A68, $010842, $010624, $010410, $010204,
    $010000, $00FE03, $00FC0F, $00FA23, $00F83E, $00F660, $00F489, $00F2B9,
    $00F0F0, $00EF2E, $00ED73, $00EBBD, $00EA0E, $00E865, $00E6C2, $00E525,
    $00E38E, $00E1FC, $00E070, $00DEE9, $00DD67, $00DBEB, $00DA74, $00D901,
    $00D794, $00D62B, $00D4C7, $00D368, $00D20D, $00D0B6, $00CF64, $00CE16,
    $00CCCC, $00CB87, $00CA45, $00C907, $00C7CE, $00C698, $00C565, $00C437,
    $00C30C, $00C1E4, $00C0C0, $00BFA0, $00BE82, $00BD69, $00BC52, $00BB3E,
    $00BA2E, $00B921, $00B817, $00B70F, $00B60B, $00B509, $00B40B, $00B30F,
    $00B216, $00B11F, $00B02C, $00AF3A, $00AE4C, $00AD60, $00AC76, $00AB8F,
    $00AAAA, $00A9C8, $00A8E8, $00A80A, $00A72F, $00A655, $00A57E, $00A4A9,
    $00A3D7, $00A306, $00A237, $00A16B, $00A0A0, $009FD8, $009F11, $009E4C,
    $009D89, $009CC8, $009C09, $009B4C, $009A90, $0099D7, $00991F, $009868,
    $0097B4, $009701, $00964F, $0095A0, $0094F2, $009445, $00939A, $0092F1,
    $009249, $0091A2, $0090FD, $00905A, $008FB8, $008F17, $008E78, $008DDA,
    $008D3D, $008CA2, $008C08, $008B70, $008AD8, $008A42, $0089AE, $00891A,
    $008888, $0087F7, $008767, $0086D9, $00864B, $0085BF, $008534, $0084A9,
    $008421, $008399, $008312, $00828C, $008208, $008184, $008102, $008080,
    $000000, $100000, $16A09E, $1BB67A, $200000, $23C6EF, $27311C, $2A54FF,
    $2D413C, $300000, $3298B0, $3510E5, $376CF5, $39B056, $3BDDD4, $3DF7BD,
    $400000, $41F83D, $43E1DB, $45BE0C, $478DDE, $49523A, $4B0BF1, $4CBBB9,
    $4E6238, $500000, $519595, $532370, $54A9FE, $5629A2, $57A2B7, $591590,
    $5A8279, $5BE9BA, $5D4B94, $5EA843, $600000, $6152FE, $62A170, $63EB83,
    $653160, $667332, $67B11D, $68EB44, $6A21CA, $6B54CD, $6C846C, $6DB0C2,
    $6ED9EB, $700000, $712318, $72434A, $7360AD, $747B54, $759354, $76A8BF,
    $77BBA8, $78CC1F, $79DA34, $7AE5F9, $7BEF7A, $7CF6C8, $7DFBEF, $7EFEFD,
    $800000, $80FF01, $81FC0F, $82F734, $83F07B, $84E7EE, $85DD98, $86D182,
    $87C3B6, $88B43D, $89A31F, $8A9066, $8B7C19, $8C6641, $8D4EE4, $8E360B,
    $8F1BBC, $900000, $90E2DB, $91C456, $92A475, $938341, $9460BD, $953CF1,
    $9617E2, $96F196, $97CA11, $98A159, $997773, $9A4C64, $9B2031, $9BF2DE,
    $9CC470, $9D94EB, $9E6454, $9F32AF, $A00000, $A0CC4A, $A19792, $A261DC,
    $A32B2A, $A3F382, $A4BAE6, $A5815A, $A646E1, $A70B7E, $A7CF35, $A89209,
    $A953FD, $AA1513, $AAD550, $AB94B4, $AC5345, $AD1103, $ADCDF2, $AE8A15,
    $AF456E, $B00000, $B0B9CC, $B172D6, $B22B20, $B2E2AC, $B3997C, $B44F93,
    $B504F3, $B5B99D, $B66D95, $B720DC, $B7D375, $B88560, $B936A0, $B9E738,
    $BA9728, $BB4673, $BBF51A, $BCA320, $BD5086, $BDFD4E, $BEA979, $BF5509,
    $C00000, $C0AA5F, $C15428, $C1FD5C, $C2A5FD, $C34E0D, $C3F58C, $C49C7D,
    $C542E1, $C5E8B8, $C68E05, $C732C9, $C7D706, $C87ABB, $C91DEB, $C9C098,
    $CA62C1, $CB0469, $CBA591, $CC463A, $CCE664, $CD8612, $CE2544, $CEC3FC,
    $CF623A, $D00000, $D09D4E, $D13A26, $D1D689, $D27277, $D30DF3, $D3A8FC,
    $D44394, $D4DDBC, $D57774, $D610BE, $D6A99B, $D7420B, $D7DA0F, $D871A9,
    $D908D8, $D99F9F, $DA35FE, $DACBF5, $DB6185, $DBF6B0, $DC8B76, $DD1FD8,
    $DDB3D7, $DE4773, $DEDAAD, $DF6D86, $E00000, $E09219, $E123D4, $E1B530,
    $E24630, $E2D6D2, $E36719, $E3F704, $E48694, $E515CB, $E5A4A8, $E6332D,
    $E6C15A, $E74F2F, $E7DCAD, $E869D6, $E8F6A9, $E98326, $EA0F50, $EA9B26,
    $EB26A8, $EBB1D9, $EC3CB7, $ECC743, $ED517F, $EDDB6A, $EE6506, $EEEE52,
    $EF7750, $F00000, $F08861, $F11076, $F1983E, $F21FBA, $F2A6EA, $F32DCF,
    $F3B469, $F43AB9, $F4C0C0, $F5467D, $F5CBF2, $F6511E, $F6D602, $F75A9F,
    $F7DEF5, $F86305, $F8E6CE, $F96A52, $F9ED90, $FA708A, $FAF33F, $FB75B1,
    $FBF7DF, $FC79CA, $FCFB72, $FD7CD8, $FDFDFB, $FE7EDE, $FEFF7F, $FF7FDF,
    $000000, $03243A, $064855, $096C32, $0C8FB2, $0FB2B7, $12D520, $15F6D0,
    $1917A6, $1C3785, $1F564E, $2273E1, $259020, $28AAED, $2BC428, $2EDBB3,
    $31F170, $350540, $381704, $3B269F, $3E33F2, $413EE0, $444749, $474D10,
    $4A5018, $4D5043, $504D72, $534789, $563E69, $5931F7, $5C2214, $5F0EA4,
    $61F78A, $64DCA9, $67BDE5, $6A9B20, $6D7440, $704927, $7319BA, $75E5DD,
    $78AD74, $7B7065, $7E2E93, $80E7E4, $839C3C, $864B82, $88F59A, $8B9A6B,
    $8E39D9, $90D3CC, $93682A, $95F6D9, $987FBF, $9B02C5, $9D7FD1, $9FF6CA,
    $A26799, $A4D224, $A73655, $A99414, $ABEB49, $AE3BDD, $B085BA, $B2C8C9,
    $B504F3, $B73A22, $B96841, $BB8F3A, $BDAEF9, $BFC767, $C1D870, $C3E200,
    $C5E403, $C7DE65, $C9D112, $CBBBF7, $CD9F02, $CF7A1F, $D14D3D, $D31848,
    $D4DB31, $D695E4, $D84852, $D9F269, $DB941A, $DD2D53, $DEBE05, $E04621,
    $E1C597, $E33C59, $E4AA59, $E60F87, $E76BD7, $E8BF3B, $EA09A6, $EB4B0B,
    $EC835E, $EDB293, $EED89D, $EFF573, $F10908, $F21352, $F31447, $F40BDD,
    $F4FA0A, $F5DEC6, $F6BA07, $F78BC5, $F853F7, $F91297, $F9C79D, $FA7301,
    $FB14BE, $FBACCD, $FC3B27, $FCBFC9, $FD3AAB, $FDABCB, $FE1323, $FE70AF,
    $FEC46D, $FF0E57, $FF4E6D, $FF84AB, $FFB10F, $FFD397, $FFEC43, $FFFB10,
    $000000, $00A2F9, $0145F6, $01E8F8, $028C01, $032F14, $03D234, $047564,
    $0518A5, $05BBFB, $065F68, $0702EF, $07A692, $084A54, $08EE38, $099240,
    $0A366E, $0ADAC7, $0B7F4C, $0C2401, $0CC8E7, $0D6E02, $0E1355, $0EB8E3,
    $0F5EAE, $1004B9, $10AB08, $11519E, $11F87D, $129FA9, $134725, $13EEF4,
    $149719, $153F99, $15E875, $1691B2, $173B53, $17E55C, $188FD1, $193AB4,
    $19E60A, $1A91D8, $1B3E20, $1BEAE7, $1C9831, $1D4602, $1DF45F, $1EA34C,
    $1F52CE, $2002EA, $20B3A3, $216500, $221705, $22C9B8, $237D1E, $24313C,
    $24E618, $259BB9, $265224, $27095F, $27C171, $287A61, $293436, $29EEF6,
    $2AAAAA, $2B6759, $2C250A, $2CE3C7, $2DA398, $2E6485, $2F2699, $2FE9DC,
    $30AE59, $31741B, $323B2C, $330398, $33CD6B, $3498B1, $356578, $3633CE,
    $3703C1, $37D560, $38A8BB, $397DE4, $3A54EC, $3B2DE6, $3C08E6, $3CE601,
    $3DC54D, $3EA6E3, $3F8ADC, $407152, $415A62, $42462C, $4334D0, $442671,
    $451B37, $46134A, $470ED6, $480E0C, $491120, $4A184C, $4B23CD, $4C33EA,
    $4D48EC, $4E6327, $4F82F9, $50A8C9, $51D50A, $53083F, $5442FC, $5585EA,
    $56D1CC, $582782, $598815, $5AF4BC, $5C6EED, $5DF86C, $5F9369, $6142A3,
    $6309A5, $64ED1E, $66F381, $692617, $6B9322, $6E52A5, $71937C, $75CEB4,
    $000000, $000324, $000648, $00096D, $000C93, $000FBA, $0012E2, $00160B,
    $001936, $001C63, $001F93, $0022C4, $0025F9, $002930, $002C6B, $002FA9,
    $0032EB, $003632, $00397C, $003CCB, $00401F, $004379, $0046D8, $004A3D,
    $004DA8, $005119, $005492, $005811, $005B99, $005F28, $0062C0, $006660,
    $006A09, $006DBC, $00717A, $007541, $007914, $007CF2, $0080DC, $0084D2,
    $0088D5, $008CE6, $009105, $009533, $009970, $009DBE, $00A21C, $00A68B,
    $00AB0D, $00AFA2, $00B44B, $00B909, $00BDDC, $00C2C6, $00C7C8, $00CCE3,
    $00D218, $00D767, $00DCD3, $00E25D, $00E806, $00EDCF, $00F3BB, $00F9CA,
    $010000, $01065C, $010CE2, $011394, $011A73, $012183, $0128C6, $01303E,
    $0137EF, $013FDC, $014808, $015077, $01592D, $01622D, $016B7D, $017522,
    $017F21, $018980, $019444, $019F76, $01AB1C, $01B73E, $01C3E7, $01D11F,
    $01DEF1, $01ED69, $01FC95, $020C83, $021D44, $022EE9, $024186, $025533,
    $026A09, $028025, $0297A7, $02B0B5, $02CB78, $02E823, $0306EC, $032815,
    $034BEB, $0372C6, $039D10, $03CB47, $03FE02, $0435F7, $047405, $04B93F,
    $0506FF, $055EF9, $05C35D, $063709, $06BDCF, $075CE6, $081B97, $09046D,
    $0A2736, $0B9CC6, $0D8E81, $1046E9, $145AFF, $1B2671, $28BC48, $517BB5,
    $FFFFFF, $FFFB10, $FFEC43, $FFD397, $FFB10F, $FF84AB, $FF4E6D, $FF0E57,
    $FEC46D, $FE70AF, $FE1323, $FDABCB, $FD3AAB, $FCBFC9, $FC3B27, $FBACCD,
    $FB14BE, $FA7301, $F9C79D, $F91297, $F853F7, $F78BC5, $F6BA07, $F5DEC6,
    $F4FA0A, $F40BDD, $F31447, $F21352, $F10908, $EFF573, $EED89D, $EDB293,
    $EC835E, $EB4B0B, $EA09A6, $E8BF3B, $E76BD7, $E60F87, $E4AA59, $E33C59,
    $E1C597, $E04621, $DEBE05, $DD2D53, $DB941A, $D9F269, $D84852, $D695E4,
    $D4DB31, $D31848, $D14D3D, $CF7A1F, $CD9F02, $CBBBF7, $C9D112, $C7DE65,
    $C5E403, $C3E200, $C1D870, $BFC767, $BDAEF9, $BB8F3A, $B96841, $B73A22,
    $B504F3, $B2C8C9, $B085BA, $AE3BDD, $ABEB49, $A99414, $A73655, $A4D224,
    $A26799, $9FF6CA, $9D7FD1, $9B02C5, $987FBF, $95F6D9, $93682A, $90D3CC,
    $8E39D9, $8B9A6B, $88F59A, $864B82, $839C3C, $80E7E4, $7E2E93, $7B7065,
    $78AD74, $75E5DD, $7319BA, $704927, $6D7440, $6A9B20, $67BDE5, $64DCA9,
    $61F78A, $5F0EA4, $5C2214, $5931F7, $563E69, $534789, $504D72, $4D5043,
    $4A5018, $474D10, $444749, $413EE0, $3E33F2, $3B269F, $381704, $350540,
    $31F170, $2EDBB3, $2BC428, $28AAED, $259020, $2273E1, $1F564E, $1C3785,
    $1917A6, $15F6D0, $12D520, $0FB2B7, $0C8FB2, $096C32, $064855, $03243A
  );

{ TSnesCX4 }

constructor TSnesCX4.Create(ReadBus: TCx4Read; WriteBus: TCx4Write; MapBus: TCx4Map);
begin
  inherited Create;
  FRead := ReadBus;
  FWrite := WriteBus;
  FMap := MapBus;
  Reset;
end;

procedure TSnesCX4.Reset;
begin
  // Mesen resets registers, preserving both program cache and data RAM.
  State := Default(TCx4State);
  State.Stopped := True;
  State.SingleRom := True;
  State.RomAccessDelay := 3;
  State.RamAccessDelay := 3;
  FIRQ := False;
  FTarget := 0;
end;

procedure TSnesCX4.Tick(Cycles: UInt64);
begin
  if State.Bus.Enabled then
    if State.Bus.DelayCycles > Cycles then
      Dec(State.Bus.DelayCycles, Byte(Cycles))
    else
    begin
      State.Bus.Enabled := False;
      State.Bus.DelayCycles := 0;
      if State.Bus.Reading then
      begin
        State.MemoryDataReg := FRead(State.Bus.Address);
        State.Bus.Reading := False;
      end;
      if State.Bus.Writing then
      begin
        FWrite(State.Bus.Address, Byte(State.MemoryDataReg));
        State.Bus.Writing := False;
      end;
    end;
  Inc(State.CycleCount, Cycles);
end;

procedure TSnesCX4.Stop;
begin
  State.Stopped := True;
  if not State.IrqDisabled then
  begin
    State.IrqFlag := True;
    FIRQ := True;
  end;
end;

function TSnesCX4.AccessDelay(Address: Cardinal): Byte;
begin
  Result := 1;
  case FMap(Address) of
    ROM:
      Inc(Result, State.RomAccessDelay);
    SRAM:
      Inc(Result, State.RamAccessDelay);
  end;
end;

function TSnesCX4.ProcessCache(Target: UInt64): Boolean;
begin
  var Address := (State.Cache.Base + (Cardinal(State.PB) shl 9)) and $FFFFFF;
  if State.Cache.Pos = 0 then
  begin
    if not State.Cache.Preload then
    begin
      if State.Cache.Address[State.Cache.Page] = Address then
      begin
        State.Cache.Enabled := False;
        Exit(True);
      end;
      State.Cache.Page := State.Cache.Page xor 1;
      if State.Cache.Address[State.Cache.Page] = Address then
      begin
        State.Cache.Enabled := False;
        Exit(True);
      end;
      if State.Cache.Lock[State.Cache.Page] then
        State.Cache.Page := State.Cache.Page xor 1;
      if State.Cache.Lock[State.Cache.Page] then
      begin
        State.Cache.Enabled := False;
        Exit(False);
      end;
    end;
    State.Cache.Enabled := True;
  end;

  while State.Cache.Pos < 256 do
  begin
    var Addr := Address + Cardinal(State.Cache.Pos) * 2;
    var L := FRead(Addr);
    Tick(AccessDelay(Addr));
    var H := FRead(Addr + 1);
    Tick(AccessDelay(Addr + 1));
    ProgramRAM[State.Cache.Page, State.Cache.Pos] := (Word(H) shl 8) or L;
    Inc(State.Cache.Pos);
    if State.CycleCount >= Target then
      Break;
  end;
  Result := State.Cache.Pos >= 256;
  if Result then
  begin
    State.Cache.Address[State.Cache.Page] := Address;
    State.Cache.Pos := 0;
    State.Cache.Enabled := False;
    State.Cache.Preload := False;
  end;
end;

procedure TSnesCX4.SwitchCachePage;
begin
  if State.Cache.Page = 1 then
  begin
    Stop;
    Exit;
  end;
  State.Cache.Page := 1;
  if State.Cache.Lock[1] then
  begin
    Stop;
    Exit;
  end;

  State.PB := State.P;
  if not ProcessCache(FTarget) and not State.Cache.Enabled then
    Stop;
end;

procedure TSnesCX4.ProcessDMA(Target: UInt64);
begin
  while State.Dma.Pos < State.Dma.Length do
  begin
    var Src := (State.Dma.Source + State.Dma.Pos) and $FFFFFF;
    var Dest := (State.Dma.Dest + State.Dma.Pos) and $FFFFFF;
    var SrcType := FMap(Src);
    var DestType := FMap(Dest);
    if (SrcType = Unmapped) or (DestType = Unmapped) or (SrcType = DestType) or (DestType = ROM) then
    begin
      State.Locked := True;
      State.Dma.Pos := 0;
      State.Dma.Enabled := False;
      Exit;
    end;
    Tick(AccessDelay(Src));
    var Value := FRead(Src);
    Tick(AccessDelay(Dest));
    FWrite(Dest, Value);
    Inc(State.Dma.Pos);
    if State.CycleCount >= Target then
      Break;
  end;
  if State.Dma.Pos >= State.Dma.Length then
  begin
    State.Dma.Pos := 0;
    State.Dma.Enabled := False;
  end;
end;

procedure TSnesCX4.RunUntil(Target: UInt64);
begin
  FTarget := Target;
  while State.CycleCount < Target do
  begin
    if State.Locked then
      Tick(1)
    else if State.Suspend.Enabled then
    begin
      Tick(1);
      if State.Suspend.Duration > 0 then
      begin
        Dec(State.Suspend.Duration);
        if State.Suspend.Duration = 0 then
          State.Suspend.Enabled := False;
      end;
    end
    else if State.Cache.Enabled then
      ProcessCache(Target)
    else if State.Dma.Enabled then
      ProcessDMA(Target)
    else if State.Stopped then
      Tick(Target - State.CycleCount)
    else if not ProcessCache(Target) then
    begin
      if not State.Cache.Enabled then
        Stop;
    end
    else
    begin
      var Opcode := ProgramRAM[State.Cache.Page, State.PC];
      State.PC := (Integer(State.PC) + 1) and $FF;
      if State.PC = 0 then
        SwitchCachePage;
      Execute(Opcode);
    end;
  end;
end;

function TSnesCX4.Source(Index: Byte): Cardinal;
const
  Constants: array[0..15] of Cardinal = ($000000, $FFFFFF, $00FF00, $FF0000, $00FFFF, $FFFF00,
    $800000, $7FFFFF, $008000, $007FFF, $FF7FFF, $FFFF7F, $010000, $FEFFFF, $000100, $00FEFF);
begin
  Index := Index and $7F;
  case Index of
    0:
      Exit(State.A);
    1:
      Exit((State.Mult shr 24) and $FFFFFF);
    2:
      Exit(State.Mult and $FFFFFF);
    3:
      Exit(State.MemoryDataReg);
    8:
      Exit(State.RomBuffer);
    $C:
      Exit(State.RamBuffer[0] or (Cardinal(State.RamBuffer[1]) shl 8) or (Cardinal(State.RamBuffer[2]) shl 16));
    $13:
      Exit(State.MemoryAddressReg);
    $1C:
      Exit(State.DataPointerReg);
    $20:
      Exit(State.PC);
    $28:
      Exit(State.P);
    $2E, $2F:
      begin
        State.Bus.Enabled := True;
        State.Bus.Reading := True;
        State.Bus.Address := State.MemoryAddressReg;
        if Index = $2E then
          State.Bus.DelayCycles := State.RomAccessDelay
        else
          State.Bus.DelayCycles := State.RamAccessDelay;
      end;
    $50..$5F:
      Exit(Constants[Index and $F]);
    $60..$7F:
      Exit(State.Regs[Index and $F]);
  end;
  Result := 0;
end;

procedure TSnesCX4.StoreRegister(Index: Byte; Value: Cardinal);
begin
  Index := Index and $7F;
  Value := Value and $FFFFFF;
  case Index of
    1:
      State.Mult := (State.Mult and $FFFFFF) or (UInt64(Value) shl 24);
    2:
      State.Mult := (State.Mult and $FFFFFF000000) or Value;
    3:
      State.MemoryDataReg := Value;
    8:
      State.RomBuffer := Value;
    $C:
      begin
        State.RamBuffer[0] := Byte(Value);
        State.RamBuffer[1] := Byte(Value shr 8);
        State.RamBuffer[2] := Byte(Value shr 16);
      end;
    $13:
      State.MemoryAddressReg := Value;
    $1C:
      State.DataPointerReg := Value;
    $20:
      State.PC := Byte(Value);
    $28:
      State.P := Value and $7FFF;
    $2E, $2F:
      begin
        State.Bus.Enabled := True;
        State.Bus.Writing := True;
        State.Bus.Address := State.MemoryAddressReg;
        if Index = $2E then
          State.Bus.DelayCycles := State.RomAccessDelay
        else
          State.Bus.DelayCycles := State.RamAccessDelay;
      end;
    $60..$7F:
      State.Regs[Index and $F] := Value;
  end;
end;

procedure TSnesCX4.SetNZ;
begin
  State.Negative := (State.A and $800000) <> 0;
  State.Zero := State.A = 0;
end;

procedure TSnesCX4.SetA(Value: Cardinal);
begin
  State.A := Value and $FFFFFF;
  SetNZ;
end;

function TSnesCX4.AddValues(A, B: Cardinal): Cardinal;
begin
  Result := A + B;
  State.Carry := Result > $FFFFFF;
  State.Negative := (Result and $800000) <> 0;
  State.Overflow := (not (A xor B) and (A xor Result) and $800000) <> 0;
  Result := Result and $FFFFFF;
  State.Zero := Result = 0;
end;

function TSnesCX4.Subtract(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((Int64(A) - B) and $FFFFFFFF);
  State.Carry := Integer(Result) >= 0;
  State.Negative := (Result and $800000) <> 0;
  // Preserve Mesen's CX4 overflow and zero semantics, including the full 32-bit subtraction.
  State.Overflow := (not (A xor B) and (A xor Result) and $800000) <> 0;
  State.Zero := Result = 0;
  Result := Result and $FFFFFF;
end;

procedure TSnesCX4.Branch(Take: Boolean; FarBank, Dest: Byte; Call: Boolean);
begin
  if not Take then
    Exit;
  if Call then
  begin
    State.Stack[State.SP] := (Cardinal(State.PB) shl 8) or State.PC;
    State.SP := (State.SP + 1) and 7;
  end;
  if FarBank <> 0 then
    State.PB := State.P;
  State.PC := Dest;
  Tick(2);
end;

procedure TSnesCX4.Execute(Opcode: Word);
const
  Shifts: array[0..3] of Byte = (0, 1, 8, 16);
begin
  var Op := (Opcode shr 8) and $FC;
  var P := (Opcode shr 8) and 3;
  var Q := Byte(Opcode);
  var V: Cardinal;
  var Addr: Cardinal;
  var Take: Boolean := True;
  case Op of
    $08..$18, $28..$38:
      begin
        case Op and $1F of
          $C:
            Take := State.Zero;
          $10:
            Take := State.Carry;
          $14:
            Take := State.Negative;
          $18:
            Take := State.Overflow;
        end;
        Branch(Take, P, Q, Op >= $28);
      end;
    $1C:
      if State.Bus.Enabled then
        Tick(State.Bus.DelayCycles);
    $24:
      begin
        case P of
          0:
            Take := State.Overflow;
          1:
            Take := State.Carry;
          2:
            Take := State.Zero;
          3:
            Take := State.Negative;
        end;
        if Take = ((Q and 1) <> 0) then
        begin
          State.PC := (Integer(State.PC) + 1) and $FF;
          if State.PC = 0 then
            SwitchCachePage;
          Tick(1);
        end;
      end;
    $3C:
      begin
        State.SP := (State.SP - 1) and 7;
        State.PB := (State.Stack[State.SP] shr 8) and $7FFF;
        State.PC := Byte(State.Stack[State.SP]);
        Tick(2);
      end;
    $40:
      State.MemoryAddressReg := (State.MemoryAddressReg + 1) and $FFFFFF;
    $48, $4C, $50, $54:
      begin
        if (Op and 4) = 0 then
          V := Source(Q)
        else
          V := Q;
        if Op < $50 then
          Subtract(V, State.A shl Shifts[P])
        else
          Subtract(State.A shl Shifts[P], V);
      end;
    $58:
      begin
        case P of
          1:
            State.A := Cardinal(Integer(ShortInt(State.A))) and $FFFFFF;
          2:
            State.A := Cardinal(Integer(SmallInt(State.A))) and $FFFFFF;
        end;
        if P in [1, 2] then
          SetNZ;
      end;
    $60, $64:
      begin
        if Op = $60 then
          V := Source(Q)
        else
          V := Q;
        case P of
          0:
            State.A := V;
          1:
            State.MemoryDataReg := V;
          2:
            State.MemoryAddressReg := V;
          3:
            if Op = $60 then
              State.P := V and $7FFF
            else
              State.P := V;
        end;
      end;
    $68, $6C, $E8, $EC:
      if P < 3 then
      begin
        if (Op and 4) = 0 then
          Addr := State.A and $FFF
        else
          Addr := (State.DataPointerReg + Q) and $FFF;
        if Addr >= $C00 then
          Dec(Addr, $400);
        if Op < $E0 then
          State.RamBuffer[P] := DataRAM[Addr]
        else
          DataRAM[Addr] := State.RamBuffer[P];
      end;
    $70:
      State.RomBuffer := Cx4Data[State.A and $3FF];
    $74:
      State.RomBuffer := Cx4Data[(P shl 8) or Q];
    $7C:
      case P of
        0:
          State.P := (State.P and $7F00) or Q;
        1:
          State.P := (State.P and $FF) or ((Word(Q) and $7F) shl 8);
      end;
    $80..$94:
      begin
        if (Op and 4) = 0 then
          V := Source(Q)
        else
          V := Q;
        case Op and $F8 of
          $80:
            State.A := AddValues(State.A shl Shifts[P], V);
          $88:
            State.A := Subtract(V, State.A shl Shifts[P]);
          $90:
            State.A := Subtract(State.A shl Shifts[P], V);
        end;
      end;
    $98, $9C:
      begin
        if Op = $98 then
          V := Source(Q)
        else
          V := Q;
        var SignedV := Integer(V shl 8) div 256;
      // ASR, unlike div, rounds negative values down; shifting left makes this division exact.
        State.Mult := UInt64(Int64(SignedV) * Int64(Integer(State.A shl 8) div 256)) and $FFFFFFFFFFFF;
      end;
    $A0..$BC:
      begin
        if (Op and 4) = 0 then
          V := Source(Q)
        else
          V := Q;
        case Op and $F8 of
          $A0:
            SetA(not (State.A shl Shifts[P]) xor V);
          $A8:
            SetA((State.A shl Shifts[P]) xor V);
          $B0:
            SetA((State.A shl Shifts[P]) and V);
          $B8:
            SetA((State.A shl Shifts[P]) or V);
        end;
      end;
    $C0..$DC:
      begin
        if (Op and 4) = 0 then
          V := Source(Q)
        else
          V := Q;
        V := V and $1F;
        if V < 24 then
          case Op and $F8 of
            $C0:
              State.A := (State.A shr V) and $FFFFFF;
            $C8:
              begin
                var SignedA := Integer(State.A shl 8) div 256;
                State.A := Cardinal(SignedA shr V);
                if (SignedA < 0) and (V > 0) then
                  State.A := State.A or (Cardinal($FFFFFFFF) shl (32 - V));
                State.A := State.A and $FFFFFF;
              end;
            $D0:
              State.A := ((State.A shr V) or (State.A shl (24 - V))) and $FFFFFF;
            $D8:
              State.A := (State.A shl V) and $FFFFFF;
          end;
        SetNZ;
      end;
    $E0:
      case P of
        0:
          StoreRegister(Q, State.A);
        1:
          StoreRegister(Q, State.MemoryDataReg);
      end;
    $F0:
      begin
        V := State.A;
        State.A := State.Regs[Q and $F];
        State.Regs[Q and $F] := V;
      end;
    $FC:
      Stop;
  end;
  Tick(1);
end;

function TSnesCX4.Read(Address: Cardinal): Byte;
begin
  Address := $7000 or (Address and $FFF);
  if Address <= $7BFF then
    Exit(DataRAM[Address and $FFF]);

  if (Address >= $7F60) and (Address <= $7F7F) then
    Exit(State.Vectors[Address and $1F]);

  if ((Address >= $7F80) and (Address <= $7FAF)) or ((Address >= $7FC0) and (Address <= $7FEF)) then
  begin
    Address := Address and $3F;
    Exit(Byte(State.Regs[Address div 3] shr ((Address mod 3) * 8)));
  end;

  if (Address >= $7F53) and (Address <= $7F5F) then
  begin
    var Busy := State.Cache.Enabled or State.Dma.Enabled or (State.Bus.DelayCycles > 0);
    Exit(Byte(State.Suspend.Enabled) or (Byte(State.IrqFlag) shl 1) or
      (Byte(Busy or not State.Stopped) shl 6) or (Byte(Busy) shl 7));
  end;

  case Address of
    $7F40..$7F42:
      Exit(Byte(State.Dma.Source shr ((Address - $7F40) * 8)));
    $7F43..$7F44:
      Exit(Byte(State.Dma.Length shr ((Address - $7F43) * 8)));
    $7F45..$7F47:
      Exit(Byte(State.Dma.Dest shr ((Address - $7F45) * 8)));
    $7F48:
      Exit(State.Cache.Page);
    $7F49..$7F4B:
      Exit(Byte(State.Cache.Base shr ((Address - $7F49) * 8)));
    $7F4C:
      Exit(Byte(State.Cache.Lock[0]) or (Byte(State.Cache.Lock[1]) shl 1));
    $7F4D..$7F4E:
      Exit(Byte(State.Cache.ProgramBank shr ((Address - $7F4D) * 8)));
    $7F4F:
      Exit(State.Cache.ProgramCounter);
    $7F50:
      Exit(State.RamAccessDelay or (State.RomAccessDelay shl 4));
    $7F51:
      Exit(Byte(State.IrqDisabled));
    $7F52:
      Exit(Byte(State.SingleRom));
  end;
  Result := 0;
end;

procedure SetByte(var Dest: Cardinal; Index: Cardinal; Value: Byte);
begin
  Dest := (Dest and not (Cardinal($FF) shl (Index * 8))) or (Cardinal(Value) shl (Index * 8));
end;

procedure TSnesCX4.Write(Address: Cardinal; Value: Byte);
begin
  Address := $7000 or (Address and $FFF);
  if Address <= $7BFF then
  begin
    DataRAM[Address and $FFF] := Value;
    Exit;
  end;

  if (Address >= $7F60) and (Address <= $7F7F) then
  begin
    State.Vectors[Address and $1F] := Value;
    Exit;
  end;

  if ((Address >= $7F80) and (Address <= $7FAF)) or ((Address >= $7FC0) and (Address <= $7FEF)) then
  begin
    Address := Address and $3F;
    SetByte(State.Regs[Address div 3], Address mod 3, Value);
    Exit;
  end;

  if (Address >= $7F55) and (Address <= $7F5C) then
  begin
    State.Suspend.Enabled := True;
    State.Suspend.Duration := (Address - $7F55) * 32;
    Exit;
  end;

  case Address of
    $7F40..$7F42:
      SetByte(State.Dma.Source, Address - $7F40, Value);
    $7F43:
      State.Dma.Length := (State.Dma.Length and $FF00) or Value;
    $7F44:
      State.Dma.Length := (State.Dma.Length and $FF) or (Word(Value) shl 8);
    $7F45..$7F47:
      begin
        SetByte(State.Dma.Dest, Address - $7F45, Value);
        if (Address = $7F47) and State.Stopped then
          State.Dma.Enabled := True;
      end;
    $7F48:
      begin
        State.Cache.Page := Value and 1;
        if State.Stopped then
        begin
          State.PB := State.Cache.ProgramBank;
          State.Cache.Preload := True;
          State.Cache.Enabled := True;
        end;
      end;
    $7F49..$7F4B:
      SetByte(State.Cache.Base, Address - $7F49, Value);
    $7F4C:
      begin
        State.Cache.Lock[0] := (Value and 1) <> 0;
        State.Cache.Lock[1] := (Value and 2) <> 0;
      end;
    $7F4D:
      State.Cache.ProgramBank := (State.Cache.ProgramBank and $FF00) or Value;
    $7F4E:
      State.Cache.ProgramBank := (State.Cache.ProgramBank and $FF) or ((Word(Value) and $7F) shl 8);
    $7F4F:
      begin
        State.Cache.ProgramCounter := Value;
        if State.Stopped then
        begin
          State.Stopped := False;
          State.PB := State.Cache.ProgramBank;
          State.PC := Value;
        end;
      end;
    $7F50:
      begin
        State.RamAccessDelay := Value and 7;
        State.RomAccessDelay := (Value shr 4) and 7;
      end;
    $7F51:
      begin
        State.IrqDisabled := (Value and 1) <> 0;
        if State.IrqDisabled then
        begin
          State.IrqFlag := False;
          FIRQ := False;
        end;
      end;
    $7F52:
      State.SingleRom := (Value and 1) <> 0;
    $7F53:
      begin
        State.Locked := False;
        State.Stopped := True;
      end;
    $7F5D:
      State.Suspend.Enabled := False;
    $7F5E:
      State.IrqFlag := False; // The CPU IRQ line remains asserted until $7F51 disables it.
  end;
end;

procedure TSnesCX4.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  Archive.Field(ProgramRAM, SizeOf(ProgramRAM));
  Archive.Field(DataRAM, SizeOf(DataRAM));
  Archive.Field(FIRQ, SizeOf(FIRQ));
end;

end.


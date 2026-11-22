unit NES.Mapper.Namco;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperNamco = class(TMapperBanked)
  private
    FBoard, FVariant, FSubmapper, FCounter, FProtect, FChrMode, FAudioAddr, FAudioDivider, FChannel: Integer;
    FLegacyHeader, FAutoVariant, FAudioIncrement, FPending, FMute, FNot340: Boolean;
    FPages: array[0..11] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    FAudioRam: array[0..$7F] of Byte;
    FOutput: array[0..7] of Integer;
    procedure Detect(Variant: Integer);
    function PpuOffset(Address: UInt16; out IsName: Boolean): Integer;
    procedure ClockAudio;
    function WriteSangokushi(Address: UInt16; Value: UInt8): Boolean;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; LegacyHeader: Boolean);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperChinaErSan2 = class(TMapperNamco)
  private
    FFont: TArray<Byte>;
    FZeroPage, FFrameZeroPage: array[0..$FF] of Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; const Font: TArray<Byte>; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure PowerOn; override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); override;
    procedure DrawTextOverlay(var Frame: TFrameBuffer; const Colors: array of UInt32);
  end;

implementation

const
  // Glyph numbers for the Xuanyun font encoding, as documented by the
  // CHINA_ER_SAN2 implementation in puNES (mapper_532.c).
  ChinaErSan2Glyph: array[0..9, 0..$75] of Word = (
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $000, $000, $000, $000, $000, $130, $131, $126, $000,
    $000, $151, $000, $000, $39F, $132, $0C8, $133, $134, $135, $3A0, $3A1,
    $3A2, $152, $000, $000, $000, $000, $000, $000, $0FF, $34D, $138, $0C5,
    $25B, $1C2, $3A3, $3A4, $017, $3A5, $364, $029, $120, $000, $000, $3A6,
    $311, $39F, $39F, $39F, $39F, $39F, $39F, $39F, $39F, $39F, $39F, $39F,
    $000, $000, $000, $000, $000, $000, $000, $000, $000, $000) { tile group $1 },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $000, $001, $002, $003, $004, $005, $006, $007, $008,
    $009, $00A, $00B, $00C, $00D, $00E, $00F, $010, $011, $012, $013, $014,
    $015, $016, $017, $018, $019, $01A, $01B, $01C, $01D, $01E, $01F, $020,
    $021, $022, $023, $024, $025, $026, $027, $028, $029, $02A, $02B, $02C,
    $02D, $02E, $02F, $030, $1B9, $1BA, $1BB, $1BC, $1BD, $1BE, $1BF, $1C0,
    $1C1, $1C2, $1C3, $1C4, $1C5, $1C6, $1C7, $1C8, $1C9, $1CA, $1CB, $1CC,
    $1CD, $1CE, $1CF, $1D0, $1D1, $1D2, $1D3, $1D4, $1D5, $1D6, $1D7, $1D8,
    $1D9, $1DA, $1DB, $1DC, $1DD, $1DE, $1DF, $1E0, $1E1, $1E2, $1E3, $1E4,
    $1E5, $1E6, $1E7, $1E8, $1E9, $1EA, $1EB, $1EC, $1ED, $1EE) { tile group $6 },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $031, $032, $033, $034, $035, $036, $037, $038, $039,
    $03A, $03B, $03C, $03D, $03E, $03F, $040, $041, $042, $043, $044, $045,
    $046, $047, $048, $049, $04A, $04B, $04C, $04D, $04E, $04F, $050, $051,
    $052, $053, $054, $055, $056, $057, $058, $059, $05A, $05B, $05C, $05D,
    $05E, $05F, $060, $061, $1EF, $1F0, $1F1, $1F2, $1F3, $1F4, $1F5, $1F6,
    $1F7, $1F8, $1F9, $1FA, $1FB, $1FC, $1FD, $1FE, $1FF, $200, $201, $202,
    $203, $204, $205, $206, $207, $208, $209, $20A, $20B, $20C, $20D, $20E,
    $20F, $210, $211, $212, $213, $214, $215, $216, $217, $218, $219, $21A,
    $21B, $21C, $21D, $21E, $21F, $220, $221, $222, $223, $224) { tile group $7 },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $062, $063, $064, $065, $066, $067, $068, $069, $06A,
    $06B, $06C, $06D, $06E, $06F, $070, $071, $072, $073, $074, $075, $076,
    $077, $078, $079, $07A, $07B, $07C, $07D, $07E, $07F, $080, $081, $082,
    $083, $084, $085, $086, $087, $088, $089, $08A, $08B, $08C, $08D, $08E,
    $08F, $090, $091, $092, $225, $226, $227, $228, $229, $22A, $22B, $22C,
    $22D, $22E, $22F, $230, $231, $232, $233, $234, $235, $236, $237, $238,
    $239, $23A, $23B, $23C, $23D, $23E, $23F, $240, $241, $242, $243, $244,
    $245, $246, $247, $248, $249, $24A, $24B, $24C, $24D, $24E, $24F, $250,
    $251, $252, $253, $254, $255, $256, $257, $258, $259, $25A) { tile group $8 },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $093, $094, $095, $096, $097, $098, $099, $09A, $09B,
    $09C, $09D, $09E, $09F, $0A0, $0A1, $0A2, $0A3, $0A4, $0A5, $0A6, $0A7,
    $0A8, $0A9, $0AA, $0AB, $0AC, $0AD, $0AE, $0AF, $0B0, $0B1, $0B2, $0B3,
    $0B4, $0B5, $0B6, $0B7, $0B8, $0B9, $0BA, $0BB, $0BC, $0BD, $0BE, $0BF,
    $0C0, $0C1, $0C2, $0C3, $25B, $25C, $25D, $25E, $25F, $260, $261, $262,
    $263, $264, $265, $266, $267, $268, $269, $26A, $26B, $26C, $26D, $26E,
    $26F, $270, $271, $272, $273, $274, $275, $276, $277, $278, $279, $27A,
    $27B, $27C, $27D, $27E, $27F, $280, $281, $282, $283, $284, $285, $286,
    $287, $288, $289, $28A, $28B, $28C, $28D, $28E, $28F, $290) { tile group $9 },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $0C4, $0C5, $0C6, $0C7, $0C8, $0C9, $0CA, $0CB, $0CC,
    $0CD, $0CE, $0CF, $0D0, $0D1, $0D2, $0D3, $0D4, $0D5, $0D6, $0D7, $0D8,
    $0D9, $0DA, $0DB, $0DC, $0DD, $0DE, $0DF, $0E0, $0E1, $0E2, $0E3, $0E4,
    $0E5, $0E6, $0E7, $0E8, $0E9, $0EA, $0EB, $0EC, $0ED, $0EE, $0EF, $0F0,
    $0F1, $0F2, $0F3, $0F4, $291, $292, $293, $294, $295, $296, $297, $298,
    $299, $29A, $29B, $29C, $29D, $29E, $29F, $2A0, $2A1, $2A2, $2A3, $2A4,
    $2A5, $2A6, $2A7, $2A8, $2A9, $2AA, $2AB, $2AC, $2AD, $2AE, $2AF, $2B0,
    $2B1, $2B2, $2B3, $2B4, $2B5, $2B6, $2B7, $2B8, $2B9, $2BA, $2BB, $2BC,
    $2BD, $2BE, $2BF, $2C0, $2C1, $2C2, $2C3, $2C4, $2C5, $2C6) { tile group $A },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $0F5, $0F6, $0F7, $0F8, $0F9, $0FA, $0FB, $0FC, $0FD,
    $0FE, $0FF, $100, $101, $102, $103, $104, $105, $106, $107, $108, $109,
    $10A, $10B, $10C, $10D, $10E, $10F, $110, $111, $112, $113, $114, $115,
    $116, $117, $118, $119, $11A, $11B, $11C, $11D, $11E, $11F, $120, $121,
    $122, $123, $124, $125, $2C7, $2C8, $2C9, $2CA, $2CB, $2CC, $2CD, $2CE,
    $2CF, $2D0, $2D1, $2D2, $2D3, $2D4, $2D5, $2D6, $2D7, $2D8, $2D9, $2DA,
    $2DB, $2DC, $2DD, $2DE, $2DF, $2E0, $2E1, $2E2, $2E3, $2E4, $2E5, $2E6,
    $2E7, $2E8, $2E9, $2EA, $2EB, $2EC, $2ED, $2EE, $2EF, $2F0, $2F1, $2F2,
    $2F3, $2F4, $2F5, $2F6, $2F7, $2F8, $2F9, $2FA, $2FB, $2FC) { tile group $B },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $126, $127, $128, $129, $12A, $12B, $12C, $12D, $12E,
    $12F, $130, $131, $132, $133, $134, $135, $136, $137, $138, $139, $13A,
    $13B, $13C, $13D, $13E, $13F, $140, $141, $142, $143, $144, $145, $146,
    $147, $148, $149, $14A, $14B, $14C, $14D, $14E, $14F, $150, $151, $152,
    $153, $154, $155, $156, $2FD, $2FE, $2FF, $300, $301, $302, $303, $304,
    $305, $306, $307, $308, $309, $30A, $30B, $30C, $30D, $30E, $30F, $310,
    $311, $312, $313, $314, $315, $316, $317, $318, $319, $31A, $31B, $31C,
    $31D, $31E, $31F, $320, $321, $322, $323, $324, $325, $326, $327, $328,
    $329, $32A, $32B, $32C, $32D, $32E, $32F, $330, $331, $332) { tile group $C },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $157, $158, $159, $15A, $15B, $15C, $15D, $15E, $15F,
    $160, $161, $162, $163, $164, $165, $166, $167, $168, $169, $16A, $16B,
    $16C, $16D, $16E, $16F, $170, $171, $172, $173, $174, $175, $176, $177,
    $178, $179, $17A, $17B, $17C, $17D, $17E, $17F, $180, $181, $182, $183,
    $184, $185, $186, $187, $333, $334, $335, $336, $337, $338, $339, $33A,
    $33B, $33C, $33D, $33E, $33F, $340, $341, $342, $343, $344, $345, $346,
    $347, $348, $349, $34A, $34B, $34C, $34D, $34E, $34F, $350, $351, $352,
    $353, $354, $355, $356, $357, $358, $359, $35A, $35B, $35C, $35D, $35E,
    $35F, $360, $361, $362, $363, $364, $365, $366, $367, $368) { tile group $D },
    ($000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000, $000,
    $000, $000, $000, $188, $189, $18A, $18B, $18C, $18D, $18E, $18F, $190,
    $191, $192, $193, $194, $195, $196, $197, $198, $199, $19A, $19B, $19C,
    $19D, $19E, $19F, $1A0, $1A1, $1A2, $1A3, $1A4, $1A5, $1A6, $1A7, $1A8,
    $1A9, $1AA, $1AB, $1AC, $1AD, $1AE, $1AF, $1B0, $1B1, $1B2, $1B3, $1B4,
    $1B5, $1B6, $1B7, $1B8, $369, $36A, $36B, $36C, $36D, $36E, $36F, $370,
    $371, $372, $373, $374, $375, $376, $377, $378, $379, $37A, $37B, $37C,
    $37D, $37E, $37F, $380, $381, $382, $383, $384, $385, $386, $387, $388,
    $389, $38A, $38B, $38C, $38D, $38E, $38F, $390, $391, $392, $393, $394,
    $395, $396, $397, $398, $399, $39A, $39B, $39C, $39D, $39E)
 { tile group $E }
    );

constructor TMapperNamco.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; LegacyHeader: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FLegacyHeader := LegacyHeader;
  Reset;
end;

procedure TMapperNamco.Reset;
begin
  inherited;
  FCounter := 0;
  FProtect := 0;
  FChrMode := 0;
  FAudioAddr := 0;
  FAudioDivider := 0;
  FChannel := 7;
  FPending := False;
  FMute := False;
  FAudioIncrement := False;
  FNot340 := False;
  FVariant := 0;
  FAutoVariant := ((FBoard = MAPPER_NAMCO_163) and FLegacyHeader) or ((FBoard = MAPPER_NAMCO_175_340) and (FSubmapper = 0));
  if FBoard = MAPPER_NAMCO_175_340 then
    if FSubmapper = 1 then
      FVariant := 1
    else if FSubmapper = 2 then
      FVariant := 2
    else
      FVariant := 3;
  FillChar(FOutput, SizeOf(FOutput), 0);
  FillChar(FPages, SizeOf(FPages), 0);
  Prg8(0, 0);
  Prg8(1, 0);
  Prg8(2, 0);
  Prg8(3, -1);
  FRamEnabled := FVariant <= 1;
  if FBoard = MAPPER_CHINA_ER_SAN2 then
  begin
    for var Slot := 0 to 3 do
    begin
      Prg8(Slot, Slot - 4);
      FPages[8 + Slot] := $E0 or (Slot and 1);
    end;
    for var Slot := 0 to 7 do
      FPages[Slot] := Slot;
    FProtect := $FF;
  end;
  if FBoard = MAPPER_SANGOKUSHI_NAMCOT then
  begin
    Prg8(1, 1);
    Prg8(2, 2);
    for var Slot := 0 to 7 do
      FPages[Slot] := Slot;
    FPages[10] := 1;
    FPages[11] := 1;
  end;
end;

procedure TMapperNamco.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FVariant, SizeOf(FVariant));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FProtect, SizeOf(FProtect));
  State.Field(FChrMode, SizeOf(FChrMode));
  State.Field(FAudioAddr, SizeOf(FAudioAddr));
  State.Field(FAudioDivider, SizeOf(FAudioDivider));
  State.Field(FChannel, SizeOf(FChannel));
  State.Field(FAutoVariant, SizeOf(FAutoVariant));
  State.Field(FNot340, SizeOf(FNot340));
  State.Field(FAudioIncrement, SizeOf(FAudioIncrement));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FMute, SizeOf(FMute));
  State.Field(FPages, SizeOf(FPages));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FAudioRam, SizeOf(FAudioRam));
  State.Field(FOutput, SizeOf(FOutput));
end;

procedure TMapperNamco.Detect(Variant: Integer);
begin
  if FAutoVariant and (not FNot340 or (Variant <> 2)) then
    FVariant := Variant;
  FRamEnabled := FVariant <= 1;
end;

function TMapperNamco.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_SANGOKUSHI_NAMCOT then
  begin
    if (Address and $F800) <> $4800 then
      Exit(inherited CpuRead(Address, Value));
    Value := FAudioRam[FAudioAddr];
    if FAudioIncrement then
      FAudioAddr := (FAudioAddr + 1) and $7F;
    Exit(True);
  end;
  case Address and $F800 of
    $4800:
      begin
        Value := FAudioRam[FAudioAddr];
        if FAudioIncrement and (FAudioAddr < $7F) then
          Inc(FAudioAddr);
        Exit(True)
      end;
    $5000:
      begin
        Value := FCounter and $FF;
        Exit(True)
      end;
    $5800:
      begin
        Value := FCounter shr 8;
        Exit(True)
      end;
  end;
  Result := inherited;
end;

function TMapperNamco.WriteSangokushi(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  case Address of
    $4800..$4FFF:
      begin
        FAudioRam[FAudioAddr] := Value;
        if FAudioIncrement then
          FAudioAddr := (FAudioAddr + 1) and $7F;
      end;
    $8000..$BFFF:
      if (Address and $400) = 0 then
        FPages[(Address shr 11) and 7] := Value
      else if (Address and $2000) = 0 then
        FCounter := (FCounter and $FF00) or Value
      else
      begin
        FCounter := (FCounter and $FF) or (Value shl 8);
        FPending := False;
      end;
    $C000..$DFFF:
      if (Address and $400) = 0 then
        FPages[8 + ((Address shr 11) and 3)] := Value and 1;
    $E000..$F7FF:
      if (Address and $400) = 0 then
        Prg8((Address shr 11) and 3, Value);
    $F800..$FFFF:
      begin
        FAudioAddr := Value and $7F;
        FAudioIncrement := (Value and $80) <> 0;
      end;
  else
    Result := inherited CpuWrite(Address, Value);
  end;
end;

function TMapperNamco.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_SANGOKUSHI_NAMCOT then
    Exit(WriteSangokushi(Address, Value));
  if (Address >= $6000) and (Address < $8000) then
  begin
    FNot340 := True;
    if FVariant = 2 then
      Detect(3);
    var Enable := (FVariant = 0) and ((FProtect and $40) <> 0) and ((FProtect and (1 shl ((Address - $6000) shr 11))) = 0);
    if FVariant = 1 then
      Enable := (FProtect and 1) <> 0;
    if Enable then
      FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;

  case Address and $F800 of
    $4800:
      begin
        Detect(0);
        FAudioRam[FAudioAddr] := Value;
        if FAudioIncrement and (FAudioAddr < $7F) then
          Inc(FAudioAddr)
      end;
    $5000:
      begin
        Detect(0);
        FCounter := (FCounter and $FF00) or Value;
        FPending := False
      end;
    $5800:
      begin
        Detect(0);
        FCounter := (FCounter and $FF) or (Value shl 8);
        FPending := False
      end;
    $8000..$B800:
      FPages[(Address - $8000) shr 11] := Value;
    $C000..$D800:
      begin
        if Address >= $C800 then
          Detect(0)
        else if FVariant <> 0 then
          Detect(1);
        if FVariant = 1 then
          FProtect := Value
        else
          FPages[8 + ((Address - $C000) shr 11)] := Value;
      end;
    $E000:
      begin
        if (Value and $80) <> 0 then
          Detect(2)
        else if ((Value and $40) <> 0) and (FVariant <> 0) then
          Detect(2);
        Prg8(0, Value and $3F);
        if FVariant = 2 then
          case Value shr 6 of
            0:
              Mirror(2);
            1:
              Mirror(0);
            2:
              Mirror(3);
            3:
              Mirror(1)
          end
        else if FVariant = 0 then
          FMute := (Value and $40) <> 0;
      end;
    $E800:
      begin
        Prg8(1, Value and $3F);
        if FVariant = 0 then
          FChrMode := Value and $C0
      end;
    $F000:
      Prg8(2, Value and $3F);
    $F800:
      begin
        Detect(0);
        if FVariant = 0 then
        begin
          FProtect := Value;
          FAudioAddr := Value and $7F;
          FAudioIncrement := (Value and $80) <> 0
        end
      end;
  else
    Exit(False)
  end;

  Result := True;
end;

function TMapperNamco.PpuOffset(Address: UInt16; out IsName: Boolean): Integer;
begin
  var Slot := Address shr 10;
  if Slot >= 12 then
    Dec(Slot, 4);
  var Bank := FPages[Slot];
  IsName := (FBoard <> MAPPER_SANGOKUSHI_NAMCOT) and (FVariant = 0) and (Bank >= $E0) and ((Slot >= 8) or ((FChrMode and ($40 shl (Slot shr 2))) = 0));
  if IsName then
    Result := (Bank and 1) * $400 + (Address and $3FF)
  else
    Result := (Bank * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperNamco.NameTableOffset(Address: UInt16): UInt16;
begin
  if FBoard = MAPPER_SANGOKUSHI_NAMCOT then
    Exit((FPages[8 + ((Address shr 10) and 3)] shl 10) or (Address and $3FF));
  Result := inherited NameTableOffset(Address);
end;

function TMapperNamco.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := (Address < $2000) or ((FBoard <> MAPPER_SANGOKUSHI_NAMCOT) and
    (FVariant = 0) and (Address < $3F00));
  if not Result then
    Exit;

  var IsName: Boolean;
  var Offset := PpuOffset(Address, IsName);
  if IsName then
    Value := FNameRam[Offset]
  else
    Value := FChrMemory[Offset];
end;

function TMapperNamco.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) or ((FBoard <> MAPPER_SANGOKUSHI_NAMCOT) and
    (FVariant = 0) and (Address < $3F00));
  if not Result then
    Exit;

  var IsName: Boolean;
  var Offset := PpuOffset(Address, IsName);
  if IsName then
    FNameRam[Offset] := Value
  else if FHasChrRam then
    FChrMemory[Offset] := Value
  else
    Result := False;
end;

procedure TMapperNamco.ClockAudio;
begin
  if FMute then
    Exit;

  Inc(FAudioDivider);
  if FAudioDivider < 15 then
    Exit;

  FAudioDivider := 0;
  var Base := $40 + FChannel * 8;
  var Phase := Integer(FAudioRam[Base + 1]) or (Integer(FAudioRam[Base + 3]) shl 8) or (Integer(FAudioRam[Base + 5]) shl 16);
  var Frequency := Integer(FAudioRam[Base]) or (Integer(FAudioRam[Base + 2]) shl 8) or ((Integer(FAudioRam[Base + 4]) and 3) shl 16);
  Phase := (Phase + Frequency) mod ((256 - (FAudioRam[Base + 4] and $FC)) shl 16);
  var Pos := ((Phase shr 16) + FAudioRam[Base + 6]) and $FF;
  var Wave := (FAudioRam[Pos shr 1] shr ((Pos and 1) * 4)) and 15;
  FOutput[FChannel] := (Wave - 8) * (FAudioRam[Base + 7] and 15);
  FAudioRam[Base + 1] := Phase and $FF;
  FAudioRam[Base + 3] := (Phase shr 8) and $FF;
  FAudioRam[Base + 5] := (Phase shr 16) and $FF;
  Dec(FChannel);
  if FChannel < 7 - ((FAudioRam[$7F] shr 4) and 7) then
    FChannel := 7;
end;

procedure TMapperNamco.ClockCpu;
begin
  if FBoard = MAPPER_SANGOKUSHI_NAMCOT then
  begin
    if (FCounter and $8000) <> 0 then
    begin
      FCounter := (FCounter + 1) and $FFFF;
      if FCounter = 0 then
        FPending := True;
    end;
  end
  else if ((FCounter and $8000) <> 0) and ((FCounter and $7FFF) <> $7FFF) then
  begin
    Inc(FCounter);
    if (FCounter and $7FFF) = $7FFF then
      FPending := True
  end;
  if FVariant = 0 then
    ClockAudio;
end;

function TMapperNamco.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperNamco.ExpansionAudio: Double;
begin
  Result := 0;
  if (FVariant <> 0) or FMute then
    Exit;

  var Channels := ((FAudioRam[$7F] shr 4) and 7) + 1;
  for var i := 8 - Channels to 7 do
    Result := Result + FOutput[i];
  Result := Result / (Channels * 480.0);
end;

function TMapperNamco.GetSaveMemory: TByteArray;
begin
  Result := inherited;
  if (FBoard = MAPPER_NAMCO_163) or (FBoard = MAPPER_CHINA_ER_SAN2) then
  begin
    SetLength(Result, $2080);
    Move(FAudioRam[0], Result[$2000], $80)
  end;
end;

procedure TMapperNamco.SetSaveMemory(const Data: TByteArray);
begin
  if ((FBoard = MAPPER_NAMCO_163) or (FBoard = MAPPER_CHINA_ER_SAN2)) and (Length(Data) = $2080) then
  begin
    Move(Data[0], FPrgRam[0], $2000);
    Move(Data[$2000], FAudioRam[0], $80)
  end
  else
    inherited;
end;

constructor TMapperChinaErSan2.Create(const Prg, Chr: TByteArray; const Font: TArray<Byte>; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_CHINA_ER_SAN2, Prg, Chr, HasChrRam, MirrorMode, 0, False);
  FFont := Copy(Font);
end;

procedure TMapperChinaErSan2.PowerOn;
begin
  inherited;
  FillChar(FZeroPage, SizeOf(FZeroPage), 0);
  FillChar(FFrameZeroPage, SizeOf(FFrameZeroPage), 0);
end;

procedure TMapperChinaErSan2.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FZeroPage, SizeOf(FZeroPage));
  State.Field(FFrameZeroPage, SizeOf(FFrameZeroPage));
end;

procedure TMapperChinaErSan2.CpuRamWrite(Address: UInt16; Value: UInt8);
begin
  if Address <= $FF then
    FZeroPage[Address] := Value;
end;

procedure TMapperChinaErSan2.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  if Line = 0 then
    FFrameZeroPage := FZeroPage;
end;

procedure TMapperChinaErSan2.DrawTextOverlay(var Frame: TFrameBuffer; const Colors: array of UInt32);
var
  FirstRow, TileRowDelta, FineY, Base: Integer;
  HasText, ExtendedText, Special: Boolean;

  procedure DrawGlyph(Glyph, X, Y: Integer; Color: UInt32);
  begin
    if (Glyph = 0) or ((Glyph + 1) * 32 > Length(FFont)) then
      Exit;

    for var Dy := 0 to 15 do
      if (Y + Dy >= 0) and (Y + Dy < 240) then
      begin
        var Pos := Glyph * 32 + Dy * 2;
        var Bits := (Word(FFont[Pos]) shl 8) or FFont[Pos + 1];
        for var Dx := 0 to 15 do
          if (X + Dx >= 0) and (X + Dx < 256) and ((Bits and ($8000 shr Dx)) <> 0) then
            Frame[X + Dx, Y + Dy] := Color;
      end;
  end;

begin
  if (Length(FFont) = 0) or (Length(Colors) < 16) then
    Exit;

  FirstRow := 30;
  TileRowDelta := 0;
  FineY := 0;
  Base := $2000;
  Special := False;
  HasText := FFrameZeroPage[$BA] = $08;
  ExtendedText := FFrameZeroPage[$BB] = $09;
  var TextAddress := Integer(FFrameZeroPage[$9B]) * $100 + FFrameZeroPage[$9A];
  var TextPage := Integer(FFrameZeroPage[$97]) * $400;
  var Scene := FFrameZeroPage[$60];

  case Scene of
    $01: // City officers screen
      if HasText then
      begin
        FirstRow := 21;
        if FFrameZeroPage[$6A] = $70 then
        begin
          FineY := (FFrameZeroPage[$98] and 7) + 2;
          Inc(TextAddress, TextPage);
        end
        else if FFrameZeroPage[$98] <= FFrameZeroPage[$99] then
          FineY := (FFrameZeroPage[$98] + 2) and 7
        else
          FineY := ((FFrameZeroPage[$98] + 6) and 7) + 4;
        TileRowDelta := (TextAddress - $2000) div 32 - FirstRow;
      end;
    $03: // National map
      if HasText then
      begin
        FirstRow := 20;
        TileRowDelta := (TextAddress - $2000) div 32 - FirstRow;
      end;
    $05: // Battlefield or battle summary
      if HasText then
        if FFrameZeroPage[$AF] = 8 then
          FirstRow := 0
        else
        begin
          FirstRow := 20;
          TileRowDelta := 12;
        end;
    $06: // Secondary nametable
      if HasText then
      begin
        Base := $2400;
        FirstRow := 0;
      end;
    $07: // Strategy text after a sequence of raster IRQs
      if HasText then
      begin
        FirstRow := 1;
        for var i := 0 to 3 do
        begin
          var Latch := ((FFrameZeroPage[$69 + i * 2] and $7F) shl 8) or FFrameZeroPage[$68 + i * 2];
          Inc(FirstRow, (($7FFF - Latch) * 3) div 2728);
        end;
        TileRowDelta := (TextAddress + TextPage - $2000) div 32 - FirstRow;
      end;
    $08:
      if FFrameZeroPage[$BD] = $B3 then
      begin
        FirstRow := 14;
        Special := True;
      end;
    $0A, $0B:
      if HasText then
      begin
        FirstRow := 20;
        TileRowDelta := (TextAddress + TextPage - $2000) div 32 - FirstRow;
      end;
  end;

  for var Row := FirstRow to 29 do
  begin
    if (Row = 20) and (Scene = 5) and (FFrameZeroPage[$CB] = 9) and (TileRowDelta = 0) then
      TileRowDelta := 12;
    var TileRow := Row + TileRowDelta;
    if (TileRow < 0) or (TileRow >= 96) then
      Continue;

    var Group := 1;
    var LetterCount := 0;
    var PrefixWidth := 0;
    for var Column := 0 to 31 do
    begin
      var Offset := TileRow * 32 + Column;
      var TextY := Row * 8 - FineY - 2;
      if Offset > $800 then
      begin
        Dec(Offset, $400);
        Dec(TextY, 16);
      end;

      var TileAddress := Word(Base + Offset);
      var Code: Byte;
      if not PpuRead(TileAddress, Code) then
        Continue;

      if Code < $0F then
      begin
        Group := Code;
        if Group < 5 then
        begin
          LetterCount := 0;
          PrefixWidth := 0;
        end
        else
          Inc(PrefixWidth, 8);
        Continue;
      end;

      var Color := 7;
      if Special and (Code > $C7) then
        Dec(Code, $90)
      else if not Special and (Code < $76) and (ExtendedText or (Code < $40)) then
      begin
        var InTableRow := (TileAddress and $3FF) shr 5;
        var AttrAddress := (TileAddress and $FC00) + $3C0 + (InTableRow shr 2) * 8 + (Column shr 2);
        var Attr: Byte;
        if not PpuRead(AttrAddress, Attr) then
          Attr := 0;
        Color := ((Attr shr ((Column and 2) or ((InTableRow and 2) shl 1))) and 3) * 4;
      end
      else
      begin
        LetterCount := 0;
        PrefixWidth := 0;
        Continue;
      end;

      if (Code < $76) and ((Group = 1) or (Group >= 6)) then
      begin
        var GlyphGroup := 0;
        if Group >= 6 then
          GlyphGroup := Group - 5;
        DrawGlyph(ChinaErSan2Glyph[GlyphGroup, Code],
          Column * 8 + LetterCount * 4 - PrefixWidth, TextY, Colors[Color]);
      end;
      Inc(LetterCount);
    end;
  end;
end;

end.


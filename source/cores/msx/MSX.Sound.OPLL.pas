unit MSX.Sound.OPLL;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TOPLLPatch = record
    TL, FB, EG, ML, AR, DR, SL, RR, KR, KL, AM, PM, WS: Integer;
  end;

  TOPLLSlot = record
    Kind, Patch, Phase, PhaseOut, Output, Previous, State, Volume, Key, Sustain, TLL, RKS, RateHigh, RateLow, Shift, Envelope, FNumber, Block: Integer;
    KeepPhase, Dirty: Boolean;
  end;

  TYM2413 = class
  private
    FRegisters: array[0..63] of Byte;
    FAddress: Byte;
    FSlots: array[0..17] of TOPLLSlot;
    FPatches: array[0..37] of TOPLLPatch;
    FPatchNumbers: array[0..8] of Integer;
    FWave: array[0..1, 0..1023] of Word;
    FCounter, FPMPhase, FAMPhase, FAM, FNoise, FShortNoise: Integer;
    FRhythm: Boolean;
    FClock: Integer;
    FPhase, FFiltered: Double;
    FFilter: TPCMLowPass;
    FDC: TPCMDCBlocker;
    procedure DecodePatch(Index: Integer; const Bytes: array of Byte);
    procedure SetPatch(Channel, Index: Integer);
    procedure UpdateRhythm;
    procedure UpdateKeys;
    procedure UpdateSlot(I: Integer);
    procedure Envelope(I: Integer);
    procedure Noise(Cycles: Integer);
    function Linear(I, Phase, AM: Integer): Integer;
    function OperatorOutput(I, Modulation: Integer): Integer;
  public
    constructor Create(Clock: Integer = 3579545);
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte);
    procedure WritePort(Port, Value: Byte);
    function GenerateNative: SmallInt;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

const
  egAttack = 0;
  egDecay = 1;
  egSustain = 2;
  egRelease = 3;
  egDamp = 4;
  ExpTable: array[0..255] of Integer = (
    0, 3, 6, 8, 11, 14, 17, 20, 22, 25, 28, 31, 34, 37, 40, 42,
    45, 48, 51, 54, 57, 60, 63, 66, 69, 72, 75, 78, 81, 84, 87, 90,
    93, 96, 99, 102, 105, 108, 111, 114, 117, 120, 123, 126, 130, 133, 136, 139,
    142, 145, 148, 152, 155, 158, 161, 164, 168, 171, 174, 177, 181, 184, 187, 190,
    194, 197, 200, 204, 207, 210, 214, 217, 220, 224, 227, 231, 234, 237, 241, 244,
    248, 251, 255, 258, 262, 265, 268, 272, 276, 279, 283, 286, 290, 293, 297, 300,
    304, 308, 311, 315, 318, 322, 326, 329, 333, 337, 340, 344, 348, 352, 355, 359,
    363, 367, 370, 374, 378, 382, 385, 389, 393, 397, 401, 405, 409, 412, 416, 420,
    424, 428, 432, 436, 440, 444, 448, 452, 456, 460, 464, 468, 472, 476, 480, 484,
    488, 492, 496, 501, 505, 509, 513, 517, 521, 526, 530, 534, 538, 542, 547, 551,
    555, 560, 564, 568, 572, 577, 581, 585, 590, 594, 599, 603, 607, 612, 616, 621,
    625, 630, 634, 639, 643, 648, 652, 657, 661, 666, 670, 675, 680, 684, 689, 693,
    698, 703, 708, 712, 717, 722, 726, 731, 736, 741, 745, 750, 755, 760, 765, 770,
    774, 779, 784, 789, 794, 799, 804, 809, 814, 819, 824, 829, 834, 839, 844, 849,
    854, 859, 864, 869, 874, 880, 885, 890, 895, 900, 906, 911, 916, 921, 927, 932,
    937, 942, 948, 953, 959, 964, 969, 975, 980, 986, 991, 996, 1002, 1007, 1013, 1018);
  QuarterSine: array[0..255] of Integer = (
    2137, 1731, 1543, 1419, 1326, 1252, 1190, 1137, 1091, 1050, 1013, 979, 949, 920, 894, 869,
    846, 825, 804, 785, 767, 749, 732, 717, 701, 687, 672, 659, 646, 633, 621, 609,
    598, 587, 576, 566, 556, 546, 536, 527, 518, 509, 501, 492, 484, 476, 468, 461,
    453, 446, 439, 432, 425, 418, 411, 405, 399, 392, 386, 380, 375, 369, 363, 358,
    352, 347, 341, 336, 331, 326, 321, 316, 311, 307, 302, 297, 293, 289, 284, 280,
    276, 271, 267, 263, 259, 255, 251, 248, 244, 240, 236, 233, 229, 226, 222, 219,
    215, 212, 209, 205, 202, 199, 196, 193, 190, 187, 184, 181, 178, 175, 172, 169,
    167, 164, 161, 159, 156, 153, 151, 148, 146, 143, 141, 138, 136, 134, 131, 129,
    127, 125, 122, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 100, 98, 96,
    94, 92, 91, 89, 87, 85, 83, 82, 80, 78, 77, 75, 74, 72, 70, 69,
    67, 66, 64, 63, 62, 60, 59, 57, 56, 55, 53, 52, 51, 49, 48, 47,
    46, 45, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30,
    29, 28, 27, 26, 25, 24, 23, 23, 22, 21, 20, 20, 19, 18, 17, 17,
    16, 15, 15, 14, 13, 13, 12, 12, 11, 10, 10, 9, 9, 8, 8, 7,
    7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2,
    2, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0);
  PMTable: array[0..63] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, -1, 0,
    0, 1, 2, 1, 0, -1, -2, -1, 0, 1, 3, 1, 0, -1, -3, -1,
    0, 2, 4, 2, 0, -2, -4, -2, 0, 2, 5, 2, 0, -2, -5, -2,
    0, 3, 6, 3, 0, -3, -6, -3, 0, 3, 7, 3, 0, -3, -7, -3);
  AMTable: array[0..209] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9,
    10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 12, 12, 12, 12, 12,
    12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10,
    10, 10, 10, 9, 9, 9, 9, 9, 9, 9, 9, 8, 8, 8, 8, 8,
    8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6,
    6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4,
    4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2,
    2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0,
    0, 0);
  EGSteps: array[0..31] of Integer = (
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1);
  Preset: array[0..151] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 113, 97, 30, 23, 208, 120, 0, 23,
    19, 65, 26, 13, 216, 247, 35, 19, 19, 1, 153, 0, 242, 196, 33, 35,
    17, 97, 14, 7, 141, 100, 112, 39, 50, 33, 30, 6, 225, 118, 1, 40,
    49, 34, 22, 5, 224, 113, 0, 24, 33, 97, 29, 7, 130, 129, 17, 7,
    51, 33, 45, 19, 176, 112, 0, 7, 97, 97, 27, 6, 100, 101, 16, 23,
    65, 97, 11, 24, 133, 240, 129, 7, 51, 1, 131, 17, 234, 239, 16, 4,
    23, 193, 36, 7, 248, 248, 34, 18, 97, 80, 12, 5, 210, 245, 64, 66,
    1, 1, 85, 3, 233, 144, 3, 2, 65, 65, 137, 3, 241, 228, 192, 19,
    1, 1, 24, 15, 223, 248, 106, 109, 1, 1, 0, 0, 200, 216, 167, 104,
    5, 1, 0, 0, 248, 170, 89, 85);
  Multipliers: array[0..15] of Integer = (1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30);
  KLTable: array[0..15] of Double = (0, 18, 24, 27.75, 30, 32.25, 33.75, 35.25, 36, 37.5, 38.25, 39, 39.75, 40.5, 41.25, 42);

function Sar(V, N: Integer): Integer;
begin
  if V >= 0 then
    Result := V shr N
  else
    Result := -((-V + (1 shl N) - 1) shr N);
end;

constructor TYM2413.Create(Clock: Integer);
begin
  inherited Create;
  if (Clock < 1000000) or (Clock > 16000000) then
    raise EArgumentOutOfRangeException.Create('OPLL clock');
  FClock := Clock;
  FFilter.Configure(Clock / 72.0, 14000);
  FDC.Configure(44100, 20);
  for var I := 0 to 255 do
  begin
    FWave[0, I] := QuarterSine[I];
    FWave[0, 511 - I] := QuarterSine[I];
  end;
  for var I := 0 to 511 do
  begin
    FWave[0, 512 + I] := $8000 or FWave[0, I];
    FWave[1, I] := FWave[0, I];
    FWave[1, 512 + I] := $FFF;
  end;
  Reset;
end;

procedure TYM2413.DecodePatch(Index: Integer; const Bytes: array of Byte);
begin
  for var Op := 0 to 1 do
  begin
    var P := Default(TOPLLPatch);
    P.AM := Bytes[Op] shr 7;
    P.PM := (Bytes[Op] shr 6) and 1;
    P.EG := (Bytes[Op] shr 5) and 1;
    P.KR := (Bytes[Op] shr 4) and 1;
    P.ML := Bytes[Op] and 15;
    P.KL := Bytes[2 + Op] shr 6;
    if Op = 0 then
      P.TL := Bytes[2] and 63;
    P.AR := Bytes[4 + Op] shr 4;
    P.DR := Bytes[4 + Op] and 15;
    P.SL := Bytes[6 + Op] shr 4;
    P.RR := Bytes[6 + Op] and 15;
    P.WS := (Bytes[3] shr (3 + Op)) and 1;
    if Op = 0 then
      P.FB := Bytes[3] and 7;
    FPatches[Index * 2 + Op] := P;
  end;
end;

procedure TYM2413.SetPatch(Channel, Index: Integer);
begin
  FPatchNumbers[Channel] := Index;
  for var Op := 0 to 1 do
  begin
    FSlots[Channel * 2 + Op].Patch := Index * 2 + Op;
    FSlots[Channel * 2 + Op].Dirty := True;
  end;
end;

procedure TYM2413.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FSlots, SizeOf(FSlots), 0);
  var Bytes: array[0..7] of Byte;
  for var I := 0 to 18 do
  begin
    for var J := 0 to 7 do
      Bytes[J] := Preset[I * 8 + J];
    DecodePatch(I, Bytes);
  end;
  for var I := 0 to 17 do
  begin
    FSlots[I].Kind := I mod 2;
    FSlots[I].State := egRelease;
    FSlots[I].Envelope := 127;
    FSlots[I].Dirty := True;
  end;
  for var I := 0 to 8 do
    SetPatch(I, 0);
  FCounter := 0;
  FPMPhase := 0;
  FAMPhase := 0;
  FAM := 0;
  FNoise := 1;
  FShortNoise := 0;
  FRhythm := False;
  FAddress := 0;
  FPhase := 0;
  FFiltered := 0;
  FFilter.Reset;
  FDC.Reset;
end;

procedure TYM2413.UpdateRhythm;
begin
  var R := FRegisters[$0E] and 32 <> 0;
  if R = FRhythm then
    Exit;
  FRhythm := R;
  if R then
  begin
    SetPatch(6, 16);
    SetPatch(7, 17);
    SetPatch(8, 18);
    for var I := 14 to 17 do
      FSlots[I].Kind := 3;
    FSlots[14].KeepPhase := True;
    FSlots[17].KeepPhase := True;
    FSlots[14].Volume := (FRegisters[$37] shr 4) * 4;
    FSlots[16].Volume := (FRegisters[$38] shr 4) * 4;
  end
  else
  begin
    for var I := 14 to 17 do
    begin
      FSlots[I].Kind := I mod 2;
      FSlots[I].KeepPhase := False;
    end;
    for var C := 6 to 8 do
      SetPatch(C, FRegisters[$30 + C] shr 4);
  end;
  for var I := 12 to 17 do
    FSlots[I].Dirty := True;
end;

procedure TYM2413.UpdateKeys;
begin
  var Keys := 0;
  for var C := 0 to 8 do
    if FRegisters[$20 + C] and 16 <> 0 then
      Keys := Keys or (3 shl (C * 2));
  if FRhythm then
  begin
    var R := FRegisters[$0E];
    if R and 16 <> 0 then
      Keys := Keys or (3 shl 12);
    if R and 1 <> 0 then
      Keys := Keys or (1 shl 14);
    if R and 8 <> 0 then
      Keys := Keys or (1 shl 15);
    if R and 4 <> 0 then
      Keys := Keys or (1 shl 16);
    if R and 2 <> 0 then
      Keys := Keys or (1 shl 17);
  end;
  for var I := 0 to 17 do
  begin
    var Key := (Keys shr I) and 1;
    if Key = FSlots[I].Key then
      Continue;
    FSlots[I].Key := Key;
    if Key <> 0 then
      FSlots[I].State := egDamp
    else if Odd(FSlots[I].Kind) then
      FSlots[I].State := egRelease;
    FSlots[I].Dirty := True;
  end;
end;

procedure TYM2413.WriteRegister(Index, Value: Byte);
begin
  if Index >= 64 then
    Exit;
  if ((Index >= $19) and (Index <= $1F)) or ((Index >= $29) and (Index <= $2F)) or ((Index >= $39) and (Index <= $3F)) then
    Dec(Index, 9);
  FRegisters[Index] := Value;
  case Index of
    0..7:
      begin
        DecodePatch(0, [FRegisters[0], FRegisters[1], FRegisters[2], FRegisters[3], FRegisters[4], FRegisters[5], FRegisters[6], FRegisters[7]]);
        for var I := 0 to 17 do
          if FSlots[I].Patch < 2 then
            FSlots[I].Dirty := True;
      end;
    $0E:
      begin
        UpdateRhythm;
        UpdateKeys;
      end;
    $10..$18, $20..$28:
      begin
        var C := Index and 15;
        for var Op := 0 to 1 do
        begin
          var I := C * 2 + Op;
          FSlots[I].FNumber := FRegisters[$10 + C] + (FRegisters[$20 + C] and 1) * 256;
          FSlots[I].Block := (FRegisters[$20 + C] shr 1) and 7;
          if Odd(FSlots[I].Kind) then
            FSlots[I].Sustain := (FRegisters[$20 + C] shr 5) and 1;
          FSlots[I].Dirty := True;
        end;
        UpdateKeys;
      end;
    $30..$38:
      begin
        var C := Index - $30;
        if not FRhythm or (C < 6) then
          SetPatch(C, Value shr 4)
        else if C in [7, 8] then
        begin
          FSlots[C * 2].Volume := (Value shr 4) * 4;
          FSlots[C * 2].Dirty := True;
        end;
        FSlots[C * 2 + 1].Volume := (Value and 15) * 4;
        FSlots[C * 2 + 1].Dirty := True;
      end;
  end;
end;

procedure TYM2413.WritePort(Port, Value: Byte);
begin
  if Port and 1 = 0 then
    FAddress := Value
  else
    WriteRegister(FAddress, Value);
end;

procedure TYM2413.UpdateSlot(I: Integer);
begin
  var S := FSlots[I];
  var P := FPatches[S.Patch];
  S.RKS := S.Block shr 1;
  if P.KR <> 0 then
    S.RKS := S.Block * 2 + (S.FNumber shr 8);
  var TL := P.TL;
  if Odd(S.Kind) then
    TL := S.Volume;
  S.TLL := TL * 2;
  var KSL := Trunc(KLTable[S.FNumber shr 5] - 6 * (7 - S.Block));
  if (P.KL > 0) and (KSL > 0) then
    Inc(S.TLL, Trunc((KSL shr (3 - P.KL)) / 0.375));
  var Rate := 0;
  if not ((S.Kind and 1 = 0) and (S.Key = 0)) then
    case S.State of
      egAttack:
        Rate := P.AR;
      egDecay:
        Rate := P.DR;
      egSustain:
        if P.EG = 0 then
          Rate := P.RR;
      egRelease:
        begin
          Rate := 7;
          if S.Sustain <> 0 then
            Rate := 5
          else if P.EG <> 0 then
            Rate := P.RR;
        end;
      egDamp:
        Rate := 12;
    end;
  S.RateHigh := 0;
  S.RateLow := 0;
  S.Shift := 0;
  if Rate > 0 then
  begin
    S.RateHigh := Min(15, Rate + (S.RKS shr 2));
    S.RateLow := S.RKS and 3;
    if S.State = egAttack then
    begin
      if S.RateHigh < 12 then
        S.Shift := 13 - S.RateHigh;
    end
    else if S.RateHigh < 13 then
      S.Shift := 13 - S.RateHigh;
  end;
  S.Dirty := False;
  FSlots[I] := S;
end;

procedure TYM2413.Envelope(I: Integer);
begin
  var S := FSlots[I];
  var P := FPatches[S.Patch];
  var Mask := (1 shl S.Shift) - 1;
  var EStep := 0;
  var Index: Integer;
  if S.State = egAttack then
  begin
    if (S.Envelope > 0) and (S.RateHigh > 0) and (FCounter and Mask and (not 3) = 0) then
    begin
      case S.RateHigh of
        12..14:
          begin
            Index := (FCounter and 12) shr 1;
            EStep := 16 - S.RateHigh - EGSteps[S.RateLow * 8 + Index];
          end;
        0, 15:
          ;
      else
        if EGSteps[S.RateLow * 8 + ((FCounter shr S.Shift) and 7)] <> 0 then
          EStep := 4;
      end;
      if EStep > 0 then
        S.Envelope := Max(0, S.Envelope - (S.Envelope shr EStep) - 1);
    end;
  end
  else if (S.RateHigh > 0) and (FCounter and Mask = 0) then
  begin
    case S.RateHigh of
      13:
        EStep := EGSteps[S.RateLow * 8 + (((FCounter and 12) shr 1) or (FCounter and 1))];
      14:
        EStep := EGSteps[S.RateLow * 8 + ((FCounter and 12) shr 1)] + 1;
      15:
        EStep := 2;
    else
      EStep := EGSteps[S.RateLow * 8 + ((FCounter shr S.Shift) and 7)];
    end;
    S.Envelope := Min(127, S.Envelope + EStep);
  end;
  case S.State of
    egDamp:
      if (S.Envelope >= 123) and (FCounter and Mask = 0) then
      begin
        S.State := egAttack;
        if Min(15, P.AR + (S.RKS shr 2)) = 15 then
        begin
          S.State := egDecay;
          S.Envelope := 0;
        end;
        S.Dirty := True;
        if Odd(S.Kind) then
        begin
          if not S.KeepPhase then
            S.Phase := 0;
          if S.Kind = 1 then
            if not FSlots[I - 1].KeepPhase then
              FSlots[I - 1].Phase := 0;
        end;
      end;
    egAttack:
      if S.Envelope = 0 then
      begin
        S.State := egDecay;
        S.Dirty := True;
      end;
    egDecay:
      if S.Envelope shr 3 = P.SL then
      begin
        S.State := egSustain;
        S.Dirty := True;
      end;
  end;
  if FRegisters[$0F] and 1 <> 0 then
    S.Envelope := 0;
  FSlots[I] := S;
end;

procedure TYM2413.Noise(Cycles: Integer);
begin
  for var I := 1 to Cycles do
  begin
    if FNoise and 1 <> 0 then
      FNoise := FNoise xor $800200;
    FNoise := FNoise shr 1;
  end;
end;

function TYM2413.Linear(I, Phase, AM: Integer): Integer;
begin
  var S := FSlots[I];
  if S.Envelope > 123 then
    Exit(0);
  var H := Integer(FWave[FPatches[S.Patch].WS, Phase and 1023]) + Min(127, S.Envelope + S.TLL + AM) * 16;
  var V := (ExpTable[(H and 255) xor 255] + 1024) shr ((H and $7F00) shr 8);
  if H and $8000 <> 0 then
    V := not V;
  Result := V * 2;
end;

function TYM2413.OperatorOutput(I, Modulation: Integer): Integer;
begin
  var S := FSlots[I];
  var P := FPatches[S.Patch];
  var AM := 0;
  if P.AM <> 0 then
    AM := FAM;
  var Phase := S.PhaseOut;
  if not Odd(I) then
  begin
    if P.FB > 0 then
      Inc(Phase, Sar(S.Previous + S.Output, 9 - P.FB));
  end
  else
    Inc(Phase, Sar(Modulation, 1) * 2);
  FSlots[I].Previous := S.Output;
  FSlots[I].Output := Linear(I, Phase, AM);
  Result := FSlots[I].Output;
end;

function TYM2413.GenerateNative: SmallInt;
begin
  var Test := FRegisters[$0F];
  if Test and 2 <> 0 then
  begin
    FPMPhase := 0;
    FAMPhase := 0;
  end
  else
  begin
    var PMInc := 1;
    var AMInc := 1;
    if Test and 8 <> 0 then
    begin
      PMInc := 1024;
      AMInc := 64;
    end;
    FPMPhase := (FPMPhase + PMInc) and 8191;
    FAMPhase := (FAMPhase + AMInc) mod (210 * 64);
  end;
  FAM := AMTable[FAMPhase shr 6];
  var HH := FSlots[14].PhaseOut;
  var CY := FSlots[17].PhaseOut;
  FShortNoise := (((HH shr 2) xor (HH shr 7)) or ((HH shr 3) xor (CY shr 5)) or ((CY shr 3) xor (CY shr 5))) and 1;
  FCounter := (FCounter + 1) and $FFFF;
  for var I := 0 to 17 do
  begin
    if FSlots[I].Dirty then
      UpdateSlot(I);
    Envelope(I);
    var S := FSlots[I];
    var P := FPatches[S.Patch];
    var PM := 0;
    if P.PM <> 0 then
      PM := PMTable[((S.FNumber shr 6) and 7) * 8 + ((FPMPhase shr 10) and 7)];
    if Test and 4 <> 0 then
      S.Phase := 0;
    S.Phase := (S.Phase + ((((S.FNumber * 2 + PM) * Multipliers[P.ML]) shl S.Block) shr 2)) and $7FFFF;
    S.PhaseOut := S.Phase shr 9;
    FSlots[I] := S;
  end;
  var Sum := 0;
  for var C := 0 to 6 do
  begin
    var V := OperatorOutput(C * 2 + 1, OperatorOutput(C * 2, 0));
    if FRhythm and (C = 6) then
      Inc(Sum, V)
    else
      Inc(Sum, Sar(-V, 1));
  end;
  Noise(14);
  if not FRhythm then
    Inc(Sum, Sar(-OperatorOutput(15, OperatorOutput(14, 0)), 1))
  else
  begin
    var Phase := $D0;
    if FShortNoise <> 0 then
    begin
      Phase := $234;
      if FNoise and 1 <> 0 then
        Phase := $2D0;
    end
    else if FNoise and 1 <> 0 then
      Phase := $34;
    Inc(Sum, Linear(14, Phase, 0));
    Phase := $100;
    if FSlots[15].PhaseOut and $100 <> 0 then
    begin
      Phase := $200;
      if FNoise and 1 <> 0 then
        Phase := $300;
    end
    else if FNoise and 1 <> 0 then
      Phase := 0;
    Inc(Sum, Linear(15, Phase, 0));
  end;
  Noise(2);
  if not FRhythm then
    Inc(Sum, Sar(-OperatorOutput(17, OperatorOutput(16, 0)), 1))
  else
  begin
    Inc(Sum, Linear(16, FSlots[16].PhaseOut, 0));
    var Phase := $100;
    if FShortNoise <> 0 then
      Phase := $300;
    Inc(Sum, Linear(17, Phase, 0));
  end;
  Noise(2);
  Result := ((Sum + 32768) and $FFFF) - 32768;
end;

procedure TYM2413.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / (72.0 * 44100);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    FFiltered := FFilter.Process(GenerateNative);
  end;
  Left := EnsureRange(Round(FDC.Process(FFiltered)), -32768, 32767);
  Right := Left;
end;

end.


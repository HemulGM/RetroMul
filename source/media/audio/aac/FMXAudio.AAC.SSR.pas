unit FMXAudio.AAC.SSR;

// SSR gain control and IPQF, adapted from OxideAV/oxideav-aac.
// Copyright (c) 2026 Karpeles Lab Inc. MIT; see Licenses/OxideAAC-MIT.txt.
// ISO/IEC 14496-3 4.6.12: four-band inverse filterbank and gain ladders.

interface

uses
  FMXAudio.Bitstream, FMXAudio.Transform;

type
  TSSRGainWindow = record
    Count: Integer;
    Level, Location: array[0..6] of Integer;
  end;

  TSSRGainData = record
    MaxBand: Integer;
    Windows: array[0..3, 0..7] of TSSRGainWindow;
  end;

  TAACSSR = class
  private
    FLength, FShort, FPreviousShape, FHistoryPosition: Integer;
    FLongMDCT, FShortMDCT: TInverseMDCT;
    FWindows: array[0..1, 0..1] of TFloatSamples;
    FPreviousGain, FTail: array[0..3] of TFloatSamples;
    FHistory: array[0..3, 0..23] of Double;
    FFilter: array[0..3, 0..95] of Double;
    FPending: TFloatSamples;
    procedure Gain(Band, Sequence: Integer; const Data: TSSRGainData; var Samples: TFloatSamples);
    procedure Overlap(Band, Sequence: Integer; const Input: TFloatSamples; out Output: TFloatSamples);
  public
    constructor Create(FrameLength: Integer);
    destructor Destroy; override;
    procedure Reset;
    procedure Synthesize(const Spectrum: array of Double; Sequence, Shape: Integer; const Data: TSSRGainData; out Samples: TFloatSamples);
  end;

procedure ReadAACSSRControl(var Bits: TBitReader; Sequence: Integer; out Data: TSSRGainData);

implementation

uses
  System.SysUtils, System.Math, FMXAudio.Types;

// SSR_Q_BEGIN
const
  SSR_Q: array[0..47] of Double = (
    9.765529100757551e-5,
    1.3809589379038567e-4,
    9.840074925662353e-5,
    -8.667154478233572e-5,
    -4.6217998911921346e-4,
    -1.0211814095158174e-3,
    -1.6772149340010668e-3,
    -2.253333895141108e-3,
    -2.4987888343213967e-3,
    -2.139081596676188e-3,
    -9.559539745459777e-4,
    1.1172111530118943e-3,
    3.909130912734858e-3,
    6.963570342011867e-3,
    9.559544215947834e-3,
    1.081576654002136e-2,
    9.87705149917153e-3,
    6.156256729132736e-3,
    -4.179394606362971e-4,
    -9.212874309770764e-3,
    -1.883077587336902e-2,
    -2.7226498457701823e-2,
    -3.2022840857588906e-2,
    -3.099633252775461e-2,
    -2.2656858741499447e-2,
    -6.803111385896335e-3,
    1.5085400948280744e-2,
    3.975099338827274e-2,
    6.244536362943674e-2,
    7.762232774872133e-2,
    7.996833849613293e-2,
    6.561549306847558e-2,
    3.331365830088269e-2,
    -1.4691563058190206e-2,
    -7.230789047533415e-2,
    -1.2993222541703875e-1,
    -1.7551641029040532e-1,
    -1.9626543957670528e-1,
    -1.807333067021503e-1,
    -1.2097653136035738e-1,
    -1.4377370758549035e-2,
    1.3522730742860303e-1,
    3.1737852699301633e-1,
    5.159002179848223e-1,
    7.108002037976138e-1,
    8.80906324884448e-1,
    1.0068321641150089e0,
    1.0737914947736096e0
  );
// SSR_Q_END

procedure ReadAACSSRControl(var Bits: TBitReader; Sequence: Integer; out Data: TSSRGainData);
const
  COUNTS: array[0..3] of Integer = (1, 2, 8, 2);
var
  Width, Previous: Integer;
begin
  Data := Default(TSSRGainData);
  Data.MaxBand := Bits.ReadBits(2);
  for var Band := 1 to Data.MaxBand do
    for var Window := 0 to COUNTS[Sequence] - 1 do
    begin
      Width := 5;
      if Sequence = 2 then
        Width := 2
      else if Sequence = 1 then
      begin
        if Window = 0 then
          Width := 4
        else
          Width := 2
      end
      else if (Sequence = 3) and (Window = 0) then
        Width := 4;
      Data.Windows[Band, Window].Count := Bits.ReadBits(3);
      Previous := -1;
      for var n := 0 to Data.Windows[Band, Window].Count - 1 do
      begin
        Data.Windows[Band, Window].Level[n] := Integer(Bits.ReadBits(4)) - 4;
        Data.Windows[Band, Window].Location[n] := Integer(Bits.ReadBits(Width)) * 8;
        if Data.Windows[Band, Window].Location[n] < Previous then
          raise EPlayerFormat.Create('Nonmonotone SSR gain ladder');
        Previous := Data.Windows[Band, Window].Location[n];
      end;
    end;
end;

constructor TAACSSR.Create(FrameLength: Integer);
var
  Q, Angle: Double;
begin
  inherited Create;
  FLength := FrameLength div 4;
  FShort := FLength div 8;
  FLongMDCT := TInverseMDCT.Create(FLength);
  FShortMDCT := TInverseMDCT.Create(FShort);
  for var Shape := 0 to 1 do
  begin
    FWindows[Shape, 0] := AACWindow(FLength, Shape = 1);
    FWindows[Shape, 1] := AACWindow(FShort, Shape = 1);
  end;
  for var Band := 0 to 3 do
    for var Tap := 0 to 95 do
    begin
      if Tap < 48 then
        Q := SSR_Q[Tap]
      else
        Q := SSR_Q[95 - Tap];
      Angle := (2 * Band + 1) * (2 * Tap - 3) * Pi / 16;
      FFilter[Band, Tap] := Q * Cos(Angle);
    end;
  Reset;
end;

destructor TAACSSR.Destroy;
begin
  FLongMDCT.Free;
  FShortMDCT.Free;
  inherited;
end;

procedure TAACSSR.Reset;
begin
  FPreviousShape := 0;
  FHistoryPosition := 0;
  FPending := nil;
  FillChar(FHistory, SizeOf(FHistory), 0);
  for var Band := 0 to 3 do
  begin
    SetLength(FPreviousGain[Band], FLength);
    SetLength(FTail[Band], FLength);
    for var n := 0 to FLength - 1 do
    begin
      FPreviousGain[Band, n] := 1;
      FTail[Band, n] := 0
    end;
  end;
end;

procedure TAACSSR.Gain(Band, Sequence: Integer; const Data: TSSRGainData; var Samples: TFloatSamples);
var
  FMD: array[0..7] of TFloatSamples;
  Head: array[0..7] of Double;
  Locations, Levels: array[0..8] of Integer;
  Count, Windows, Endpoint, Flat, Index, Size: Integer;
  Exponent, Modification: Double;
begin
  Flat := (FLength - FShort) div 2;
  if (Band = 0) or (Band > Data.MaxBand) then
  begin
    Size := FLength;
    if Sequence in [1, 2] then
      Size := FShort;
    for var n := 0 to Size - 1 do
      FPreviousGain[Band, n] := 1;
    Exit;
  end;
  Windows := 1;
  if Sequence in [1, 3] then
    Windows := 2
  else if Sequence = 2 then
    Windows := 8;
  for var Window := 0 to Windows - 1 do
  begin
    Endpoint := FLength;
    if Sequence = 2 then
      Endpoint := FShort
    else if Sequence = 1 then
    begin
      if Window = 0 then
        Endpoint := Flat
      else
        Endpoint := FShort
    end
    else if (Sequence = 3) and (Window = 0) then
      Endpoint := Flat;
    Count := Data.Windows[Band, Window].Count;
    Locations[0] := 0;
    Levels[0] := 0;
    for var n := 0 to Count - 1 do
    begin
      Locations[n + 1] := Data.Windows[Band, Window].Location[n];
      Levels[n + 1] := Data.Windows[Band, Window].Level[n];
      if Locations[n + 1] >= Endpoint then
        raise EPlayerFormat.Create('SSR gain location exceeds window');
    end;
    if Count > 0 then
      Levels[0] := Levels[1];
    Locations[Count + 1] := Endpoint;
    Levels[Count + 1] := 0;
    Head[Window] := Power(2, Levels[0]);
    SetLength(FMD[Window], Endpoint);
    Index := 0;
    for var n := 0 to Endpoint - 1 do
    begin
      while (Index < Count) and (Locations[Index + 1] <= n) do
        Inc(Index);
      if n <= Locations[Index] + 7 then
        Exponent := ((8 - n + Locations[Index]) * Levels[Index] + (n - Locations[Index]) * Levels[Index + 1]) / 8
      else
        Exponent := Levels[Index + 1];
      FMD[Window, n] := Power(2, Exponent);
    end;
  end;
  if Sequence = 2 then
  begin
    for var Window := 0 to 7 do
      for var n := 0 to FShort * 2 - 1 do
      begin
        if n < FShort then
        begin
          if Window = 0 then
            Modification := Head[Window] * FPreviousGain[Band, n]
          else
            Modification := Head[Window] * FMD[Window - 1, n];
        end
        else
          Modification := FMD[Window, n - FShort];
        Samples[Window * FShort * 2 + n] := Samples[Window * FShort * 2 + n] / Modification;
      end;
    Move(FMD[7, 0], FPreviousGain[Band, 0], FShort * SizeOf(Double));
  end
  else
  begin
    for var n := 0 to FLength * 2 - 1 do
    begin
      Modification := 1;
      case Sequence of
        0:
          if n < FLength then
            Modification := Head[0] * FPreviousGain[Band, n]
          else
            Modification := FMD[0, n - FLength];
        1:
          if n < FLength then
            Modification := Head[0] * Head[1] * FPreviousGain[Band, n]
          else if n < FLength + Flat then
            Modification := Head[1] * FMD[0, n - FLength]
          else if n < FLength + Flat + FShort then
            Modification := FMD[1, n - FLength - Flat];
        3:
          if n < Flat then
            Modification := 1
          else if n < Flat + FShort then
            Modification := Head[0] * Head[1] * FPreviousGain[Band, n - Flat]
          else if n < FLength then
            Modification := Head[1] * FMD[0, n - Flat - FShort]
          else
            Modification := FMD[1, n - FLength];
      end;
      Samples[n] := Samples[n] / Modification;
    end;
    Index := 0;
    if Sequence in [1, 3] then
      Index := 1;
    Move(FMD[Index, 0], FPreviousGain[Band, 0], Length(FMD[Index]) * SizeOf(Double));
  end;
end;

procedure TAACSSR.Overlap(Band, Sequence: Integer; const Input: TFloatSamples; out Output: TFloatSamples);
var
  Flat: Integer;
begin
  Flat := (FLength - FShort) div 2;
  case Sequence of
    0:
      begin
        SetLength(Output, FLength);
        for var n := 0 to FLength - 1 do
          Output[n] := FTail[Band, n] + Input[n];
        Move(Input[FLength], FTail[Band, 0], FLength * SizeOf(Double));
      end;
    1:
      begin
        SetLength(Output, FLength + Flat);
        for var n := 0 to FLength - 1 do
          Output[n] := FTail[Band, n] + Input[n];
        Move(Input[FLength], Output[FLength], Flat * SizeOf(Double));
        Move(Input[FLength + Flat], FTail[Band, 0], FShort * SizeOf(Double));
      end;
    2:
      begin
        SetLength(Output, FLength);
        for var n := 0 to FShort - 1 do
          Output[n] := FTail[Band, n] + Input[n];
        for var w := 1 to 7 do
          for var n := 0 to FShort - 1 do
            Output[w * FShort + n] := Input[(w - 1) * FShort * 2 + FShort + n] + Input[w * FShort * 2 + n];
        Move(Input[15 * FShort], FTail[Band, 0], FShort * SizeOf(Double));
      end;
    3:
      begin
        SetLength(Output, FLength - Flat);
        for var n := 0 to FShort - 1 do
          Output[n] := FTail[Band, n] + Input[Flat + n];
        Move(Input[Flat + FShort], Output[FShort], Flat * SizeOf(Double));
        Move(Input[FLength], FTail[Band, 0], FLength * SizeOf(Double));
      end;
  end;
end;

procedure TAACSSR.Synthesize(const Spectrum: array of Double; Sequence, Shape: Integer; const Data: TSSRGainData; out Samples: TFloatSamples);
var
  Bands: array[0..3] of TFloatSamples;
  Coefficients, Time, Windowed, Full: TFloatSamples;
  WindowCount, Size, Flat, Index, Steps, QueueLength: Integer;
  Value, Sum: Double;
begin
  Size := FLength;
  WindowCount := 1;
  if Sequence = 2 then
  begin
    Size := FShort;
    WindowCount := 8
  end;
  Flat := (FLength - FShort) div 2;
  for var Band := 0 to 3 do
  begin
    SetLength(Windowed, FLength * 2);
    SetLength(Coefficients, Size);
    for var Window := 0 to WindowCount - 1 do
    begin
      for var n := 0 to Size - 1 do
      begin
        Index := n;
        if Odd(Band) then
          Index := Size - 1 - n;
        Coefficients[n] := Spectrum[Window * Size * 4 + Band * Size + Index];
      end;
      if Sequence = 2 then
        FShortMDCT.Execute(Coefficients, 0, Time)
      else
        FLongMDCT.Execute(Coefficients, 0, Time);
      for var n := 0 to Size * 2 - 1 do
      begin
        Value := 1;
        if Sequence = 2 then
        begin
          if n < Size then
          begin
            Index := Shape;
            if Window = 0 then
              Index := FPreviousShape;
            Value := FWindows[Index, 1][n];
          end
          else
            Value := FWindows[Shape, 1][Size * 2 - 1 - n];
        end
        else if n < FLength then
        begin
          if Sequence <> 3 then
            Value := FWindows[FPreviousShape, 0][n]
          else if n < Flat then
            Value := 0
          else if n < Flat + FShort then
            Value := FWindows[FPreviousShape, 1][n - Flat];
        end
        else
        begin
          if Sequence <> 1 then
            Value := FWindows[Shape, 0][FLength * 2 - 1 - n]
          else if n >= FLength + Flat + FShort then
            Value := 0
          else if n >= FLength + Flat then
            Value := FWindows[Shape, 1][FLength + Flat + FShort - 1 - n];
        end;
        Windowed[Window * Size * 2 + n] := Time[n] * Value / Size;
      end;
    end;
    Gain(Band, Sequence, Data, Windowed);
    Overlap(Band, Sequence, Windowed, Bands[Band]);
  end;
  Steps := Length(Bands[0]);
  SetLength(Full, Steps * 4);
  for var n := 0 to Steps - 1 do
  begin
    for var Band := 0 to 3 do
      FHistory[Band, FHistoryPosition] := Bands[Band, n];
    for var Phase := 0 to 3 do
    begin
      Sum := 0;
      for var Band := 0 to 3 do
        for var Tap := 0 to 23 do
          Sum := Sum + FFilter[Band, Tap * 4 + Phase] * FHistory[Band, (FHistoryPosition - Tap + 24) mod 24];
      Full[n * 4 + Phase] := Sum;
    end;
    FHistoryPosition := (FHistoryPosition + 1) mod 24;
  end;
  QueueLength := Length(FPending);
  SetLength(FPending, QueueLength + Length(Full));
  Move(Full[0], FPending[QueueLength], Length(Full) * SizeOf(Double));
  if Length(FPending) < FLength * 4 then
    raise EPlayerFormat.Create('Invalid SSR window sequence');
  Samples := Copy(FPending, 0, FLength * 4);
  FPending := Copy(FPending, FLength * 4, Length(FPending) - FLength * 4);
  FPreviousShape := Shape;
end;

end.


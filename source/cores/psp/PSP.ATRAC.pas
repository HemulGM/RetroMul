unit PSP.ATRAC;

interface

uses
  System.SysUtils, PSP.Memory, PSP.CPU, PSP.Kernel, Audio.ATRAC3Plus,
  Audio.ATRAC3;

type
  TPSPATRACContext = class
    Codec, Buffer, Capacity, DataOffset, DataSize, BlockSize, Channels, Rate: Cardinal;
    SampleCount, FirstSample, Position, NextFrame, Skip: Cardinal;
    LoopStart, LoopEnd, LoopCount: Integer;
    RequestedBytes, LastError: Cardinal;
    Encoded: TBytes;
    Decoder: TATRAC3PlusDecoder;
    Decoder3: TATRAC3Decoder;
    FrameSamples, CodingMode: Cardinal;
    PCM: TArray<SmallInt>;
    PCMOffset: Integer;
    OutputChannels: Integer;
    destructor Destroy; override;
    function Remaining: Integer;
    procedure Seek(Sample: Cardinal);
  end;

  TPSPATRAC = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FContexts: array[0..5] of TPSPATRACContext;
    FTypes: array[0..5] of Cardinal;
    function Allocate(Codec: Cardinal): Cardinal;
    function SetData(Id, Buffer, ReadSize, Capacity: Cardinal; Mono: Boolean): Cardinal;
    function Decode(Context: TPSPATRACContext; Address, Samples, Finish, Remain: Cardinal): Cardinal;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
  end;

implementation

uses
  System.Math, PSP.Media, Audio.ATRAC3Plus.Primitives{$IFDEF PSP_PROFILE},
  PSP.Profile{$ENDIF};

destructor TPSPATRACContext.Destroy;
begin
  Decoder.Free;
  Decoder3.Free;
  inherited;
end;

function TPSPATRACContext.Remaining: Integer;
begin
  if Cardinal(Length(Encoded)) >= DataOffset + DataSize then
    Exit(-1);
  Result := Max(0, (Length(Encoded) - Integer(DataOffset)) div Integer(BlockSize) - Integer(NextFrame));
end;

procedure TPSPATRACContext.Seek(Sample: Cardinal);
begin
  Position := Sample;
  var Raw := FirstSample + Sample;
  NextFrame := Raw div FrameSamples;
  if NextFrame > 0 then
    Dec(NextFrame);
  Skip := Raw - NextFrame * FrameSamples;
  PCM := nil;
  PCMOffset := 0;
  if Decoder <> nil then
    Decoder.Reset
  else
    Decoder3.Reset;
end;

constructor TPSPATRAC.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FTypes[0] := $1000;
  FTypes[1] := $1000;
  FTypes[2] := $1001;
  FTypes[3] := $1001;
end;

destructor TPSPATRAC.Destroy;
begin
  for var Context in FContexts do
    Context.Free;
  inherited;
end;

function TPSPATRAC.Allocate(Codec: Cardinal): Cardinal;
begin
  if (Codec <> $1000) and (Codec <> $1001) then
    Exit($80630004);
  for var I := 0 to High(FContexts) do
    if (FTypes[I] = Codec) and (FContexts[I] = nil) then
    begin
      FContexts[I] := TPSPATRACContext.Create;
      FContexts[I].Codec := Codec;
      FContexts[I].LoopStart := -1;
      FContexts[I].LoopEnd := -1;
      Exit(I);
    end;
  Result := $80630003;
end;

function TPSPATRAC.SetData(Id, Buffer, ReadSize, Capacity: Cardinal; Mono: Boolean): Cardinal;
begin
  if (Id > High(FContexts)) or (FContexts[Id] = nil) then
    Exit($80630005);
  if ReadSize > Capacity then
    Exit($80630013);
  if (ReadSize < 12) or (Capacity > PSPRAMSize) then
    Exit($80630011);
  if not FMemory.IsValid(Buffer, Capacity) then
    Exit($800200D3);
  var Data := FMemory.ReadBytes(Buffer, ReadSize);
  if (PSPLE32(Data, 0) <> $46464952) or (PSPLE32(Data, 8) <> $45564157) then
    Exit($80630006);
  var NewContext := TPSPATRACContext.Create;
  try
    NewContext.Codec := FContexts[Id].Codec;
    NewContext.Buffer := Buffer;
    NewContext.Capacity := Capacity;
    NewContext.LoopStart := -1;
    NewContext.LoopEnd := -1;
    var At: UInt64 := 12;
    var SampleOffset: Cardinal := 0;
    var LoopOffset: Cardinal := 0;
    var FoundFormat := False;
    var FoundData := False;
    while At + 8 <= ReadSize do
    begin
      var Kind := PSPLE32(Data, At);
      var Size := PSPLE32(Data, At + 4);
      Inc(At, 8);
      if Kind = $61746164 then
      begin
        if Size > 256 * 1024 * 1024 - At then
          Exit($80630008);
        NewContext.DataOffset := At;
        NewContext.DataSize := Size;
        FoundData := True;
        Break;
      end;
      if At + Size > ReadSize then
        Exit($80630011);
      case Kind of
        $20746D66:
          begin
            if Size < 16 then
              Exit($80630008);
            var Format := PSPLE16(Data, At);
            var Codec: Cardinal;
            case Format of
              $FFFE:
                Codec := $1000;
              $270:
                Codec := $1001;
            else
              Exit($80630006);
            end;
            if Codec <> NewContext.Codec then
              Exit($80630007);
            NewContext.Channels := PSPLE16(Data, At + 2);
            NewContext.Rate := PSPLE32(Data, At + 4);
            NewContext.BlockSize := PSPLE16(Data, At + 12);
            if not (NewContext.Channels in [1, 2]) or (NewContext.Rate <> 44100) or
              (NewContext.BlockSize = 0) or (NewContext.BlockSize > 4096) then
              Exit($80630008);
            if Codec = $1001 then
            begin
              if Size < 32 then
                Exit($80630008);
              NewContext.CodingMode := PSPLE16(Data, At + 24);
            end;
            FoundFormat := True;
          end;
        $74636166:
          begin
            if Size < 4 then
              Exit($80630008);
            NewContext.SampleCount := PSPLE32(Data, At);
            if Size >= 8 then
              SampleOffset := PSPLE32(Data, At + 4);
            LoopOffset := SampleOffset;
            if Size >= 12 then
              LoopOffset := PSPLE32(Data, At + 8);
          end;
        $6C706D73:
          if (Size >= 60) and (PSPLE32(Data, At + 28) <> 0) then
          begin
            NewContext.LoopStart := Integer(PSPLE32(Data, At + 44));
            NewContext.LoopEnd := Integer(PSPLE32(Data, At + 48));
          end;
      end;
      Inc(At, UInt64(Size) + (Size and 1));
    end;
    if not FoundFormat or not FoundData then
      Exit($80630006);
    NewContext.FrameSamples := 2048;
    if NewContext.Codec = $1001 then
      NewContext.FrameSamples := 1024;
    if Mono and (NewContext.Channels <> 1) then
      Exit($80630019);
    NewContext.OutputChannels := 2;
    if Mono then
      NewContext.OutputChannels := 1;
    NewContext.FirstSample := SampleOffset + 368;
    if NewContext.Codec = $1001 then
      NewContext.FirstSample := SampleOffset + 69;
    var TotalSamples := UInt64(NewContext.DataSize div NewContext.BlockSize) * NewContext.FrameSamples;
    if (NewContext.FirstSample > TotalSamples) or (NewContext.SampleCount > TotalSamples) then
      Exit($80630008);
    if NewContext.SampleCount = 0 then
      NewContext.SampleCount := TotalSamples - NewContext.FirstSample;
    if NewContext.LoopStart >= 0 then
    begin
      Dec(NewContext.LoopStart, LoopOffset);
      Dec(NewContext.LoopEnd, LoopOffset);
      if (NewContext.LoopStart < 0) or (NewContext.LoopStart > NewContext.LoopEnd) or
        (Cardinal(NewContext.LoopEnd) >= NewContext.SampleCount) then
        Exit($80630008);
    end;
    NewContext.Encoded := Data;
    if NewContext.Codec = $1000 then
      NewContext.Decoder := TATRAC3PlusDecoder.Create(NewContext.Channels, NewContext.OutputChannels)
    else
      NewContext.Decoder3 := TATRAC3Decoder.Create(NewContext.BlockSize, NewContext.Channels, NewContext.OutputChannels, NewContext.CodingMode);
    NewContext.Skip := NewContext.FirstSample;
    FContexts[Id].Free;
    FContexts[Id] := NewContext;
    NewContext := nil;
    Result := 0;
    FKernel.WaitUntil(FKernel.Time + 3500);
  finally
    NewContext.Free;
  end;
end;

function TPSPATRAC.Decode(Context: TPSPATRACContext; Address, Samples, Finish, Remain: Cardinal): Cardinal;
begin
  {$IFDEF PSP_PROFILE}
  var ProfileStarted := PSPProfileStart;
  try{$ENDIF}
    if (Context.Decoder = nil) and (Context.Decoder3 = nil) then
      Exit($80630010);
    if Samples <> 0 then
      FMemory.Write32(Samples, 0);
    if Finish <> 0 then
      FMemory.Write32(Finish, 0);
    if Context.Position >= Context.SampleCount then
    begin
      if Finish <> 0 then
        FMemory.Write32(Finish, 1);
      Exit($80630024);
    end;
    while Context.PCMOffset >= Length(Context.PCM) do
    begin
      var Offset := UInt64(Context.DataOffset) + UInt64(Context.NextFrame) * Context.BlockSize;
      if Offset + Context.BlockSize > Cardinal(Length(Context.Encoded)) then
        Exit($80630023);
      var Packet := Copy(Context.Encoded, Offset, Context.BlockSize);
      if Context.Decoder <> nil then
        Context.PCM := Context.Decoder.Decode(Packet)
      else
        Context.PCM := Context.Decoder3.Decode(Packet);
      Inc(Context.NextFrame);
      Context.PCMOffset := Integer(Min(Context.FrameSamples, Context.Skip)) * Context.OutputChannels;
      Dec(Context.Skip, Min(Context.FrameSamples, Context.Skip));
    end;
    var Count := Min(Cardinal((Length(Context.PCM) - Context.PCMOffset) div Context.OutputChannels), Context.SampleCount - Context.Position);
    if (Context.LoopCount <> 0) and (Context.LoopEnd >= 0) and (Context.Position <= Cardinal(Context.LoopEnd)) then
      Count := Min(Count, Cardinal(Context.LoopEnd) + 1 - Context.Position);
    if (Address <> 0) and not FMemory.IsValid(Address, Count * Cardinal(Context.OutputChannels) * 2) then
      Exit($800200D3);
    if Address <> 0 then
    begin
      var Output: TBytes;
      SetLength(Output, Integer(Count) * Context.OutputChannels * 2);
      if Length(Output) > 0 then
        Move(Context.PCM[Context.PCMOffset], Output[0], Length(Output));
      FMemory.Load(Address, Output);
    end;
    Inc(Context.PCMOffset, Integer(Count) * Context.OutputChannels);
    Inc(Context.Position, Count);
    if (Context.LoopCount <> 0) and (Context.LoopEnd >= 0) and (Context.Position = Cardinal(Context.LoopEnd) + 1) then
    begin
      if Context.LoopCount > 0 then
        Dec(Context.LoopCount);
      Context.Seek(Context.LoopStart);
    end;
    if Samples <> 0 then
      FMemory.Write32(Samples, Count);
    if Finish <> 0 then
      FMemory.Write32(Finish, Ord(Context.Position >= Context.SampleCount));
    if Remain <> 0 then
      FMemory.Write32(Remain, Cardinal(Context.Remaining));
    FKernel.WaitUntil(FKernel.Time + 1500);
    Result := 0;
  {$IFDEF PSP_PROFILE}
  finally
    PSPProfileEnd(TPSPProfilePart.ATRAC, ProfileStarted)
  end;{$ENDIF}
end;

function TPSPATRAC.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var E := FCPU.Registers[8];
  case NID of
    $780F88D1:
      begin
        Value := Allocate(A);
        Exit;
      end;
    $7A20E7AF, $0FAE370E, $472E3825, $9CD7DE03:
      begin
        if not FMemory.IsValid(A, 24) then
        begin
          Value := $80630011;
          Exit;
        end;
        var Codec: Cardinal := $1000;
        if FMemory.Read16(A + 20) = $270 then
          Codec := $1001;
        var Id := Allocate(Codec);
        Value := Id;
        if Id and $80000000 <> 0 then
          Exit;
        var Capacity := B;
        if (NID = $0FAE370E) or (NID = $9CD7DE03) then
          Capacity := C;
        Value := SetData(Id, A, B, Capacity, (NID = $472E3825) or (NID = $9CD7DE03));
        if Value = 0 then
          Value := Id
        else
          FreeAndNil(FContexts[Id]);
        Exit;
      end;
    $132F1ECA:
      begin
        for var Context in FContexts do
          if Context <> nil then
          begin
            Value := $80000021;
            Exit;
          end;
        FillChar(FTypes, SizeOf(FTypes), 0);
        var Index := 0;
        var Space := 6;
        for var I := 1 to Min(6, Integer(B)) do
        begin
          Dec(Space, 2);
          if Space < 0 then
            Break;
          FTypes[Index] := $1000;
          Inc(Index);
        end;
        for var I := 1 to Min(6, Integer(A)) do
        begin
          Dec(Space);
          if Space < 0 then
            Break;
          FTypes[Index] := $1001;
          Inc(Index);
        end;
        if Space < 0 then
          Value := $80020190;
        Exit;
      end;
    $D5C28CC0:
      Exit;
  end;
  if (A > High(FContexts)) or (FContexts[A] = nil) then
  begin
    Value := $80630005;
    Exit;
  end;
  var Context := FContexts[A];
  if NID = $61EB33F5 then
  begin
    FreeAndNil(FContexts[A]);
    Exit;
  end;
  case NID of
    $0E2A73AB, $F6837A1A:
      Value := SetData(A, B, C, C, NID = $F6837A1A);
    $3F6E26B5, $5CF9D852:
      Value := SetData(A, B, C, D, NID = $5CF9D852);
  else
    if (Context.Decoder = nil) and (Context.Decoder3 = nil) then
    begin
      Value := $80630010;
      Exit;
    end;
    case NID of
      $6A8C3CD5:
        Value := Decode(Context, B, C, D, E);
      $31668BAA:
        FMemory.Write32(B, Context.Channels);
      $B3B5D042:
        FMemory.Write32(B, Context.OutputChannels);
      $D6A5F2F7:
        FMemory.Write32(B, Context.FrameSamples);
      $A554A158:
        FMemory.Write32(B, ((Context.BlockSize * 352800 div 1000 shr 11) + 8) and $FFFFFFF0);
      $E88F759B:
        FMemory.Write32(B, Context.LastError);
      $E23E3A35:
        if Context.Position >= Context.SampleCount then
          Value := $80630024
        else
          FMemory.Write32(B, Context.Position);
      $36FAABFB:
        FMemory.Write32(B, Min(Context.FrameSamples - ((Context.FirstSample + Context.Position) mod Context.FrameSamples), Context.SampleCount - Context.Position));
      $9AE849A7:
        FMemory.Write32(B, Cardinal(Context.Remaining));
      $A2BBA8BE:
        begin
          FMemory.Write32(B, Context.SampleCount - 1);
          FMemory.Write32(C, Cardinal(Context.LoopStart));
          FMemory.Write32(D, Cardinal(Context.LoopEnd));
        end;
      $FAA4F89B:
        begin
          FMemory.Write32(B, Cardinal(Context.LoopCount));
          FMemory.Write32(C, Ord(Context.LoopStart >= 0));
        end;
      $868120B5:
        if Context.LoopStart < 0 then
          Value := $80630021
        else
          Context.LoopCount := Integer(B);
      $5D268707:
        begin
          var Offset := Cardinal(Length(Context.Encoded));
          Context.RequestedBytes := Min(Context.Capacity, Context.DataOffset + Context.DataSize - Min(Offset, Context.DataOffset + Context.DataSize));
          FMemory.Write32(B, Context.Buffer);
          FMemory.Write32(C, Context.RequestedBytes);
          FMemory.Write32(D, Offset);
        end;
      $7DB31251:
        begin
          if B > Context.RequestedBytes then
            Value := $80630018
          else
          begin
            var Offset := Length(Context.Encoded);
            if UInt64(Offset) + B > 256 * 1024 * 1024 then
              raise EPSPInstruction.Create('PSP: ATRAC stream cache exceeded 256 MiB');
            SetLength(Context.Encoded, Offset + Integer(B));
            for var I := 0 to Integer(B) - 1 do
              Context.Encoded[Offset + I] := FMemory.Read8(Context.Buffer + Cardinal(I));
            Context.RequestedBytes := 0;
          end;
        end;
      $ECA32A99:
        Value := 0;
      $83E85EA0:
        Value := $80630022;
      $644E5607:
        if B >= Context.SampleCount then
          Value := $80630015
        else
          Context.Seek(B);
    else
      Result := False;
    end;
  end;
end;

end.


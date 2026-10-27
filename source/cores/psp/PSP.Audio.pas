unit PSP.Audio;

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Memory, PSP.CPU, PSP.Kernel;

type
  TPSPPCMBlock = class
    Start, Finish: UInt64;
    Samples: TArray<SmallInt>;
  end;

  TPSPPCMChannel = record
    Reserved: Boolean;
    Count, Format, Rate, LeftVolume, RightVolume: Cardinal;
    Finish: UInt64;
  end;

  TPSPAudio = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FChannels: array[0..8] of TPSPPCMChannel;
    FBlocks: TObjectList<TPSPPCMBlock>;
    FRate: Cardinal;
    FRendered: UInt64;
    function Output(Channel, Left, Right, Address: Cardinal; Blocking: Boolean): Cardinal;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    function Render: TArray<SmallInt>;
  end;

implementation

uses
  System.Math;

constructor TPSPAudio.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FRate := 44100;
  FBlocks := TObjectList<TPSPPCMBlock>.Create(True);
end;

destructor TPSPAudio.Destroy;
begin
  FBlocks.Free;
  inherited;
end;

function TPSPAudio.Output(Channel, Left, Right, Address: Cardinal; Blocking: Boolean): Cardinal;
begin
  if Channel > 8 then
    Exit($80260003);
  if (Left > $FFFF) or (Right > $FFFF) then
    Exit($8026000B);
  var Ch: ^TPSPPCMChannel;
  Ch := @FChannels[Channel];
  if not Ch.Reserved then
    Exit($80260008);
  var Now := FKernel.Time * 44100 div 1000000;
  if (Ch.Finish > Now) and not Blocking then
    Exit($80260002);
  var Start := Max(Now, Ch.Finish);
  if Address = 0 then
  begin
    if Blocking and (Ch.Finish > Now) then
      FKernel.WaitUntil(Ch.Finish * 1000000 div 44100);
    Exit(0);
  end;
  var Channels: Cardinal := 2;
  if Ch.Format = $10 then
    Channels := 1;
  if not FMemory.IsValid(Address, Ch.Count * Channels * 2) then
    Exit($800200D3);
  var Frames := Cardinal(UInt64(Ch.Count) * 44100 div Ch.Rate);
  if FBlocks.Count > 1024 then
    raise EPSPInstruction.Create('PSP: PCM queue exceeded its bound');
  var Block := TPSPPCMBlock.Create;
  Block.Start := Start;
  Block.Finish := Start + Frames;
  SetLength(Block.Samples, Frames * 2);
  for var I := 0 to Integer(Frames) - 1 do
  begin
    var Source := Cardinal(UInt64(I) * Ch.Rate div 44100);
    var L := SmallInt(FMemory.Read16(Address + Source * Channels * 2));
    var R := L;
    if Channels = 2 then
      R := SmallInt(FMemory.Read16(Address + Source * 4 + 2));
    Block.Samples[I * 2] := EnsureRange(Integer(L) * Int64(Left) div $8000, Int64(-32768), Int64(32767));
    Block.Samples[I * 2 + 1] := EnsureRange(Integer(R) * Int64(Right) div $8000, Int64(-32768), Int64(32767));
  end;
  FBlocks.Add(Block);
  if Blocking and (Ch.Finish > Now) then
    FKernel.WaitUntil(Ch.Finish * 1000000 div 44100);
  Ch.Finish := Block.Finish;
  Result := Ch.Count;
end;

function TPSPAudio.Render: TArray<SmallInt>;
begin
  var Finish := FKernel.Time * 44100 div 1000000;
  var Count := Finish - FRendered;
  if Count > 44100 then
    raise EPSPInstruction.Create('PSP: PCM render interval exceeds one second');
  SetLength(Result, Count * 2);
  var Mix: TArray<Integer>;
  SetLength(Mix, Length(Result));
  for var Block in FBlocks do
  begin
    var First := Max(FRendered, Block.Start);
    var Last := Min(Finish, Block.Finish);
    while First < Last do
    begin
      var Dest := Integer(First - FRendered) * 2;
      var Source := Integer(First - Block.Start) * 2;
      Inc(Mix[Dest], Block.Samples[Source]);
      Inc(Mix[Dest + 1], Block.Samples[Source + 1]);
      Inc(First);
    end;
  end;
  for var I := 0 to High(Result) do
    Result[I] := EnsureRange(Mix[I], -32768, 32767);
  FRendered := Finish;
  for var I := FBlocks.Count - 1 downto 0 do
    if FBlocks[I].Finish <= Finish then
      FBlocks.Delete(I);
end;

function TPSPAudio.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  case NID of
    $5EC81C55:
      begin
        if Integer(A) < 0 then
        begin
          A := 8;
          for var I := 0 to 7 do
            if not FChannels[I].Reserved then
            begin
              A := I;
              Break;
            end;
          if A = 8 then
          begin
            Value := $80260005;
            Exit;
          end;
        end;
        if A > 7 then
          Value := $80260003
        else if FChannels[A].Reserved then
          Value := $80260003
        else if (B = 0) or (B > 65472) or (B and 63 <> 0) then
          Value := $80260006
        else if (C <> 0) and (C <> $10) then
          Value := $80260007
        else
        begin
          FChannels[A] := Default(TPSPPCMChannel);
          FChannels[A].Reserved := True;
          FChannels[A].Count := B;
          FChannels[A].Format := C;
          FChannels[A].Rate := FRate;
          Value := A;
        end;
      end;
    $6FC46853:
      if A > 7 then
        Value := $80260003
      else if not FChannels[A].Reserved then
        Value := $80260008
      else
        FChannels[A].Reserved := False;
    $8C1009B2, $136CAF51:
      Value := Output(A, B, B, C, NID = $136CAF51);
    $E2D56B2D, $13F592BC:
      Value := Output(A, B, C, D, NID = $13F592BC);
    $E9D97901, $B011922F:
      if A > 7 then
        Value := $80260003
      else
        Value := Cardinal(Max(Int64(0), Int64(FChannels[A].Finish) - Int64(FKernel.Time * 44100 div 1000000)));
    $CB2E439E, $95FD0C2D, $B7E1D8E7:
      if A > 7 then
        Value := $80260003
      else if not FChannels[A].Reserved then
        Value := $80260008
      else if NID = $CB2E439E then
        if (B = 0) or (B > 65472) or (B and 63 <> 0) then
          Value := $80260006
        else
          FChannels[A].Count := B
      else if NID = $95FD0C2D then
        if (B <> 0) and (B <> $10) then
          Value := $80260007
        else
          FChannels[A].Format := B
      else if (B > $FFFF) or (C > $FFFF) then
        Value := $8026000B
      else
      begin
        FChannels[A].LeftVolume := B;
        FChannels[A].RightVolume := C;
      end;
    $A2BEAA6C:
      if (A <> 44100) and (A <> 48000) then
        Value := $8026000A
      else
      begin
        FRate := A;
        for var I := 0 to 7 do
          FChannels[I].Rate := A;
      end;
    $01562BA3, $38553111:
      if FChannels[8].Reserved then
        Value := $80268002
      else if (A < 17) or (A > 4111) then
        Value := $80000104
      else if (NID = $38553111) and (C <> 2) then
        Value := $80000104
      else
      begin
        var Rate: Cardinal := 44100;
        if (NID = $38553111) and (B <> 0) then
          Rate := B;
        case Rate of
          8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000:
            ;
        else
          Value := $8026000A;
          Exit;
        end;
        FChannels[8] := Default(TPSPPCMChannel);
        FChannels[8].Reserved := True;
        FChannels[8].Count := A;
        FChannels[8].Rate := Rate;
      end;
    $43196845, $5C37C0AE:
      if not FChannels[8].Reserved then
        Value := $80260008
      else
        FChannels[8].Reserved := False;
    $2D53F36E, $E0727056:
      Value := Output(8, A, A, B, True);
    $647CEF33:
      Value := Cardinal(Max(Int64(0), Int64(FChannels[8].Finish) - Int64(FKernel.Time * 44100 div 1000000)));
    $63F2889C:
      if not FChannels[8].Reserved then
        Value := $80260008
      else if (A < 17) or (A > 4111) then
        Value := $80260006
      else
        FChannels[8].Count := A;
  else
    Result := False;
  end;
end;

end.


program VulkanHLEEqualBytesTest;

// VulkanHLEEqualBytes against CompareMem: sizes, alignments, mismatch
// positions, ranges ending at a guard page and an unchanged MXCSR.

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  Winapi.Windows, System.SysUtils, System.Math, RM.Vulkan.HLE;

procedure Check;
const
  Sizes: array[0..27] of Integer = (0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63,
    64, 127, 128, 129, 159, 255, 256, 257, 511, 512, 1023, 4095, 4096, 8193,
    65536, 1048576);
  Offsets: array[0..7] of Integer = (0, 1, 2, 3, 7, 15, 31, 63);
var
  A, B: TBytes;
  Cases: Integer;

  procedure Compare(P, Q: PByte; Count: NativeInt);
  begin
    var Expected := CompareMem(P, Q, Count);
    var CSR: Cardinal := $1F80 or ((Cardinal(Cases) and 3) shl 13) or
      ((Cardinal(Cases) and 4) shl 13) or ((Cardinal(Cases) and 8) shl 3) or
      (Cardinal(Cases) and $3F);
    SetMXCSR(CSR);
    SetMXCSRExceptionFlag(CSR and $3F);
    var Actual := VulkanHLEEqualBytes(P, Q, Count);
    var After := GetMXCSR;
    if (Actual <> Expected) or (After <> CSR) then
      raise Exception.CreateFmt('Memory equality mismatch count=%d expected=%d actual=%d mxcsr=%x/%x',
        [Count, Ord(Expected), Ord(Actual), CSR, After]);
    Inc(Cases);
  end;

begin
  var SavedCSR := GetMXCSR;
  Cases := 0;
  try
    SetLength(A, 1048576 + 64);
    SetLength(B, Length(A));
    for var K := 0 to High(A) do
      A[K] := Byte((K xor (K shr 5) xor (K shr 12)) and $FF);
    for var Size in Sizes do
      for var OA in Offsets do
        for var OB in Offsets do
        begin
          var P: PByte := @A[OA];
          var Q: PByte := @B[OB];
          if Size > 0 then
            Move(P^, Q^, Size);
          Compare(P, Q, Size);
          Compare(P, P, Size);
          if Size > 0 then
            for var At in TArray<Integer>.Create(0, Size div 2, Size - 1, Min(31, Size - 1), Min(127, Size - 1)) do
            begin
              Q[At] := Q[At] xor $A5;
              Compare(P, Q, Size);
              Q[At] := Q[At] xor $A5;
            end;
        end;
    Compare(nil, nil, 0);
    Compare(nil, nil, -1);

    var VA := PByte(VirtualAlloc(nil, 3 * 4096, MEM_RESERVE or MEM_COMMIT, PAGE_READWRITE));
    var VB := PByte(VirtualAlloc(nil, 3 * 4096, MEM_RESERVE or MEM_COMMIT, PAGE_READWRITE));
    try
      if (VA = nil) or (VB = nil) then
        RaiseLastOSError;
      var Old: DWORD;
      if not VirtualProtect(VA, 4096, PAGE_NOACCESS, Old) or
        not VirtualProtect(VB, 4096, PAGE_NOACCESS, Old) or
        not VirtualProtect(VA + 8192, 4096, PAGE_NOACCESS, Old) or
        not VirtualProtect(VB + 8192, 4096, PAGE_NOACCESS, Old) then
        RaiseLastOSError;
      for var Size := 0 to 4096 do
      begin
        Compare(VA + 8192 - Size, VB + 8192 - Size, Size);
        if Size > 0 then
        begin
          (VB + 8191)^ := $55;
          Compare(VA + 8192 - Size, VB + 8192 - Size, Size);
          (VB + 8191)^ := 0;
        end;
      end;
      Compare(VA, VA, High(NativeInt));
    finally
      VirtualFree(VA, 0, MEM_RELEASE);
      VirtualFree(VB, 0, MEM_RELEASE);
    end;
    Writeln(Cases, ' equality/unaligned/mismatch/tail/guard-page/MXCSR cases: OK');
  finally
    SetMXCSR(SavedCSR);
    SetMXCSRExceptionFlag(SavedCSR and $3F);
  end;
end;

begin
  try
    Check;
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.

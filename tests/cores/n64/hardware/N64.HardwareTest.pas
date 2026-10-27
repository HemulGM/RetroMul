unit N64.HardwareTest;

// The N64 core against PeterLemon's test ROMs (github.com/PeterLemon/N64, see
// fetch.ps1): each ROM in the manifest runs for 60 VIs with no input, and
// the VI's framebuffer in RDRAM (16 or 32 bits a pixel, its width from the
// VI, its height the manifest's) must hash as the ROM's expected picture
// does (manifest.ps1: FNV-1a over R, G, B, row by row; 5-bit channels
// widened as x shl 3 or x shr 2).

interface

{$Q-}{$R-}

uses
  System.Classes;

// The ROMs of Manifest (paths relative to Root); Report gets a line for each
// that differs and a summary. True: all as expected.
function RunHardwareTest(const Root, Manifest: string; Report: TStrings): Boolean;

var
  // VIs each ROM runs (the manifest's pictures are there from 60 VIs on),
  // and ROMs run at once (0: half the logical processors).
  HardwareTestFrames: Integer = 60;
  HardwareTestThreads: Integer = 0;

implementation

uses
  System.SysUtils, System.IOUtils, System.SyncObjs, System.Threading, N64.Types, N64.Console;

function FrameHash(Console: TN64Console; Width, Height: Integer): UInt64;
begin
  var Control := Console.Read32($04400000);
  var Origin := Console.Read32($04400004) and $FFFFFF;
  var Stride := Integer(Console.Read32($04400008) and $FFF);
  Result := UInt64($CBF29CE484222325);
  for var Y := 0 to Height - 1 do
    for var X := 0 to Width - 1 do
    begin
      var R, G, B: Cardinal;
      if (Control and 3) = 3 then
      begin
        var V := Console.Read32(Origin + Cardinal((Y * Stride + X) * 4));
        R := V shr 24;
        G := (V shr 16) and $FF;
        B := (V shr 8) and $FF;
      end
      else
      begin
        var A := Origin + Cardinal((Y * Stride + X) * 2);
        var V := (Cardinal(Console.Read8(A)) shl 8) or Console.Read8(A + 1);
        R := (V shr 11) and 31;
        G := (V shr 6) and 31;
        B := (V shr 1) and 31;
        R := (R shl 3) or (R shr 2);
        G := (G shl 3) or (G shr 2);
        B := (B shl 3) or (B shr 2);
      end;
      Result := (Result xor R) * UInt64($100000001B3);
      Result := (Result xor G) * UInt64($100000001B3);
      Result := (Result xor B) * UInt64($100000001B3);
    end;
end;

function RunRom(const Path: string; Width, Height: Integer): UInt64;
begin
  var Console := TN64Console.Create(TFile.ReadAllBytes(Path));
  try
    var Pads := Default(TN64Pads);
    Pads[0].Connected := True;
    Console.SetInputs(Pads);
    for var F := 1 to HardwareTestFrames do
    begin
      var Start := Console.FrameNumber;
      while Console.FrameNumber = Start do
        Console.RunInstructions(4096);
    end;
    Result := FrameHash(Console, Width, Height);
  finally
    Console.Free;
  end;
end;

function RunHardwareTest(const Root, Manifest: string; Report: TStrings): Boolean;
begin
  var Entries := TStringList.Create;
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Manifest);
    for var Line in Lines do
      if (Line.Trim <> '') and not Line.Trim.StartsWith('#') then
        Entries.Add(Line.Trim);
    // Each ROM's result line ('' as expected), filled by HardwareTestThreads
    // workers taking the ROMs in turn.
    var Results: TArray<string>;
    SetLength(Results, Entries.Count);
    var Next := -1;
    var Workers: TArray<ITask>;
    var Threads := HardwareTestThreads;
    if Threads <= 0 then
      Threads := (TThread.ProcessorCount + 1) div 2;
    SetLength(Workers, Threads);
    for var W := 0 to High(Workers) do
      Workers[W] := TTask.Run(
        procedure
        begin
          while True do
          begin
            var I := TInterlocked.Increment(Next);
            if I >= Entries.Count then
              Break;
            var F := Entries[I].Split([' ']);
            try
              var Got := RunRom(TPath.Combine(Root, F[0].Replace('/', PathDelim)), StrToInt(F[1]), StrToInt(F[2]));
              if Got <> StrToUInt64('$' + F[3]) then
                Results[I] := Format('DIFFERS %s (%.16x, expected %s)', [F[0], Got, F[3]]);
            except
              on E: Exception do
                Results[I] := Format('RAISED %s: %s: %s', [F[0], E.ClassName, E.Message]);
            end;
          end;
        end);
    TTask.WaitForAll(Workers);
    var Failed := 0;
    for var R in Results do
      if R <> '' then
      begin
        Inc(Failed);
        Report.Add(R);
      end;
    Report.Add(Format('%d ROMs: %d as expected, %d not', [Entries.Count, Entries.Count - Failed, Failed]));
    Result := (Failed = 0) and (Entries.Count > 0);
  finally
    Lines.Free;
    Entries.Free;
  end;
end;

end.

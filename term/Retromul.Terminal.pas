unit Retromul.Terminal;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes,
  System.Generics.Collections, Winapi.Windows, Core.Emulation;

type
  TTerminalRenderMode = (trmHalfBlock, trmAscii);

  TTerminalKey = record
    VirtualKey: Word;
    Character: Char;
    KeyDown: Boolean;
    RepeatCount: Word;
    Shift: Boolean;
    Ctrl: Boolean;
    Alt: Boolean;
    class function Empty: TTerminalKey; static;
  end;

  TTerminalRenderOptions = record
    Mode: TTerminalRenderMode;
    MaxWidth: Integer;
    MaxHeight: Integer;
    X: Integer;
    Y: Integer;
    KeepAspectRatio: Boolean;
    CharacterAspect: Single;
    BlackThreshold: Byte;
    class function Default: TTerminalRenderOptions; static;
  end;

  TRetromulTerminal = class
  private
    const
      DEFAULT_ASCII_CHARSET = ' .,''`-_:;~=+*@?r7TgMWB@';
  private
    class var
      FInputHandle: THandle;
      FOutputHandle: THandle;
      FOldInputMode: DWORD;
      FOldOutputMode: DWORD;
      FInitialized: Boolean;
      FAsciiCharset: string;
      FLastAvailableWidth: Integer;
      FLastAvailableHeight: Integer;

    class procedure WriteRaw(const S: string); static;
    class procedure AppendForegroundEscape(const Builder: TStringBuilder; const R, G, B: Byte); static;
    class procedure AppendBackgroundEscape(const Builder: TStringBuilder; const R, G, B: Byte); static;
    class function ColorR(const Color: TAlphaColor): Byte; static;
    class function ColorG(const Color: TAlphaColor): Byte; static;
    class function ColorB(const Color: TAlphaColor): Byte; static;
    class function Luma(const R, G, B: Byte): Byte; static;
    class function GetVirtualKeyState(const VirtualKey: Integer): Boolean; static;
    class procedure CalculateTargetSize(const BitmapWidth: Integer; const BitmapHeight: Integer; const MaxWidth: Integer; const MaxHeight: Integer; const CharacterAspect: Single; const KeepAspectRatio: Boolean; out TargetWidth: Integer; out TargetHeight: Integer); static;
    class procedure RenderHalfBlock(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions); static;
    class procedure RenderAscii(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions); static;
  public
    class constructor Create;
    class destructor Destroy;

    class procedure Initialize; static;
    class procedure Finalize; static;

    class procedure Clear; static;
    class procedure ClearLine; static;
    class procedure Home; static;

    class procedure HideCursor; static;
    class procedure ShowCursor; static;
    class procedure ResetStyle; static;

    class procedure SetTitle(const Title: string); static;

    class function Width: Integer; static;
    class function Height: Integer; static;

    class procedure MoveCursor(const X, Y: Integer); static;
    class procedure WriteText(const X, Y: Integer; const Text: string); static;
    class procedure DrawFrame(const Bitmap: TEmulatorFrame); overload; static;
    class procedure DrawFrame(const Bitmap: TEmulatorFrame; const Mode: TTerminalRenderMode; const MaxWidth: Integer = 0; const MaxHeight: Integer = 0; const X: Integer = 1; const Y: Integer = 1); overload; static;
    class procedure DrawFrame(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions); overload; static;

    class function PollKey(out Key: TTerminalKey): Boolean; static;
    class procedure FlushInput; static;
    class function IsKeyDown(const VirtualKey: Integer): Boolean; overload; static;
    class function IsKeyDown(const Key: Char): Boolean; overload; static;
    class function IsKeyPressed(const VirtualKey: Integer): Boolean; static;

    class procedure SetAsciiCharset(const Value: string); static;
    class property Initialized: Boolean read FInitialized;
  end;

implementation

{ TTerminalKey }

class function TTerminalKey.Empty: TTerminalKey;
begin
  Result := Default(TTerminalKey);
end;

{ TTerminalRenderOptions }

class function TTerminalRenderOptions.Default: TTerminalRenderOptions;
begin
  Result.Mode := trmHalfBlock;
  Result.MaxWidth := 0;
  Result.MaxHeight := 0;
  Result.X := 1;
  Result.Y := 1;
  Result.KeepAspectRatio := True;
  Result.CharacterAspect := 2.0;
  Result.BlackThreshold := 8;
end;

{ TRetromulTerminal }

class constructor TRetromulTerminal.Create;
begin
  FInputHandle := INVALID_HANDLE_VALUE;
  FOutputHandle := INVALID_HANDLE_VALUE;

  FAsciiCharset := DEFAULT_ASCII_CHARSET;
end;

class destructor TRetromulTerminal.Destroy;
begin
  if FInitialized then
    Finalize;
end;

class procedure TRetromulTerminal.Initialize;
var
  Mode: DWORD;
begin
  if FInitialized then
    Exit;

  FInputHandle := GetStdHandle(STD_INPUT_HANDLE);
  FOutputHandle := GetStdHandle(STD_OUTPUT_HANDLE);

  if (FInputHandle = 0) or (FInputHandle = INVALID_HANDLE_VALUE) then
    RaiseLastOSError;

  if (FOutputHandle = 0) or (FOutputHandle = INVALID_HANDLE_VALUE) then
    RaiseLastOSError;

  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);

  if GetConsoleMode(FInputHandle, FOldInputMode) then
  begin
    Mode := FOldInputMode;

    Mode := Mode and not ENABLE_LINE_INPUT;
    Mode := Mode and not ENABLE_ECHO_INPUT;
    Mode := Mode and not ENABLE_QUICK_EDIT_MODE;

    Mode := Mode or ENABLE_EXTENDED_FLAGS;
    Mode := Mode or ENABLE_PROCESSED_INPUT;
    Mode := Mode or ENABLE_WINDOW_INPUT;

    if not SetConsoleMode(FInputHandle, Mode) then
      RaiseLastOSError;
  end;

  if GetConsoleMode(FOutputHandle, FOldOutputMode) then
  begin
    Mode := FOldOutputMode;

    Mode := Mode or ENABLE_PROCESSED_OUTPUT;
    Mode := Mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    Mode := Mode or DISABLE_NEWLINE_AUTO_RETURN;

    if not SetConsoleMode(FOutputHandle, Mode) then
      RaiseLastOSError;
  end;

  FInitialized := True;

  ResetStyle;
  HideCursor;
end;

class procedure TRetromulTerminal.Finalize;
begin
  if not FInitialized then
    Exit;

  ResetStyle;
  ShowCursor;

  if (FInputHandle <> 0) and (FInputHandle <> INVALID_HANDLE_VALUE) then
    SetConsoleMode(FInputHandle, FOldInputMode);

  if (FOutputHandle <> 0) and (FOutputHandle <> INVALID_HANDLE_VALUE) then
    SetConsoleMode(FOutputHandle, FOldOutputMode);

  FInputHandle := INVALID_HANDLE_VALUE;
  FOutputHandle := INVALID_HANDLE_VALUE;

  FInitialized := False;
end;

class procedure TRetromulTerminal.WriteRaw(const S: string);
var
  Written: DWORD;
begin
  if S.IsEmpty then
    Exit;

  if (FOutputHandle <> 0) and (FOutputHandle <> INVALID_HANDLE_VALUE) and
    WriteConsoleW(FOutputHandle, PWideChar(S), Length(S), Written, nil)
    then
    Exit;

  System.Write(S);
end;

class procedure TRetromulTerminal.AppendForegroundEscape(const Builder: TStringBuilder; const R, G, B: Byte);
begin
  Builder.Append(#27'[38;2;');
  Builder.Append(R);
  Builder.Append(';');
  Builder.Append(G);
  Builder.Append(';');
  Builder.Append(B);
  Builder.Append('m');
end;

class procedure TRetromulTerminal.AppendBackgroundEscape(const Builder: TStringBuilder; const R, G, B: Byte);
begin
  Builder.Append(#27'[48;2;');
  Builder.Append(R);
  Builder.Append(';');
  Builder.Append(G);
  Builder.Append(';');
  Builder.Append(B);
  Builder.Append('m');
end;

class function TRetromulTerminal.ColorR(const Color: TAlphaColor): Byte;
begin
  Result := TAlphaColorRec(Color).R;
end;

class function TRetromulTerminal.ColorG(const Color: TAlphaColor): Byte;
begin
  Result := TAlphaColorRec(Color).G;
end;

class function TRetromulTerminal.ColorB(const Color: TAlphaColor): Byte;
begin
  Result := TAlphaColorRec(Color).B;
end;

class function TRetromulTerminal.Luma(const R, G, B: Byte): Byte;
begin
  Result := (Integer(R) * 54 + Integer(G) * 183 + Integer(B) * 19) shr 8;
end;

class procedure TRetromulTerminal.Clear;
begin
  WriteRaw(#27'[2J'#27'[H');
end;

class procedure TRetromulTerminal.ClearLine;
begin
  WriteRaw(#27'[2K'#13);
end;

class procedure TRetromulTerminal.Home;
begin
  WriteRaw(#27'[H');
end;

class procedure TRetromulTerminal.HideCursor;
begin
  WriteRaw(#27'[?25l');
end;

class procedure TRetromulTerminal.ShowCursor;
begin
  WriteRaw(#27'[?25h');
end;

class procedure TRetromulTerminal.ResetStyle;
begin
  WriteRaw(#27'[0m');
end;

class procedure TRetromulTerminal.SetTitle(const Title: string);
begin
  WriteRaw(#27']0;' + Title + #7);
end;

class function TRetromulTerminal.Width: Integer;
begin
  Result := 80;
  var Info: TConsoleScreenBufferInfo;
  if GetConsoleScreenBufferInfo(FOutputHandle, Info) then
    Result := Info.srWindow.Right - Info.srWindow.Left + 1;
end;

class function TRetromulTerminal.Height: Integer;
begin
  Result := 25;
  var Info: TConsoleScreenBufferInfo;
  if GetConsoleScreenBufferInfo(FOutputHandle, Info) then
    Result := Info.srWindow.Bottom - Info.srWindow.Top + 1;
end;

class procedure TRetromulTerminal.MoveCursor(const X, Y: Integer);
begin
  WriteRaw(#27'[' + Max(1, Y).ToString + ';' + Max(1, X).ToString + 'H');
end;

class procedure TRetromulTerminal.WriteText(const X, Y: Integer; const Text: string);
begin
  MoveCursor(X, Y);
  WriteRaw(Text);
end;

class procedure TRetromulTerminal.CalculateTargetSize(const BitmapWidth: Integer; const BitmapHeight: Integer; const MaxWidth: Integer; const MaxHeight: Integer; const CharacterAspect: Single; const KeepAspectRatio: Boolean; out TargetWidth: Integer; out TargetHeight: Integer);
begin
  if not KeepAspectRatio then
  begin
    TargetWidth := Max(1, MaxWidth);
    TargetHeight := Max(1, MaxHeight);
    Exit;
  end;

  var SX := MaxWidth / BitmapWidth;
  var SY := (MaxHeight * CharacterAspect) / BitmapHeight;
  var Scale := Min(SX, SY);

  TargetWidth := Max(1, Min(MaxWidth, Floor(BitmapWidth * Scale)));
  TargetHeight := Max(1, Min(MaxHeight, Floor(BitmapHeight * Scale / CharacterAspect)));
end;

class procedure TRetromulTerminal.DrawFrame(const Bitmap: TEmulatorFrame);
begin
  DrawFrame(Bitmap, TTerminalRenderOptions.Default);
end;

class procedure TRetromulTerminal.DrawFrame(const Bitmap: TEmulatorFrame; const Mode: TTerminalRenderMode; const MaxWidth: Integer; const MaxHeight: Integer; const X: Integer; const Y: Integer);
begin
  var Options := TTerminalRenderOptions.Default;

  Options.Mode := Mode;
  Options.MaxWidth := MaxWidth;
  Options.MaxHeight := MaxHeight;
  Options.X := X;
  Options.Y := Y;

  DrawFrame(Bitmap, Options);
end;

class procedure TRetromulTerminal.DrawFrame(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions);
begin
  if not FInitialized then
    Initialize;

  if Length(Bitmap.Pixels) <= 0 then
    Exit;

  case Options.Mode of
    trmHalfBlock:
      RenderHalfBlock(Bitmap, Options);
    trmAscii:
      RenderAscii(Bitmap, Options);
  end;
end;

class procedure TRetromulTerminal.RenderHalfBlock(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions);
var
  TargetWidth: Integer;
  TargetRows: Integer;
  TargetPixelHeight: Integer;
begin
  var AvailableWidth := IfThen(Options.MaxWidth > 0, Options.MaxWidth, Width - Options.X + 1);
  var AvailableHeight := IfThen(Options.MaxHeight > 0, Options.MaxHeight, Height - Options.Y + 1);

  AvailableWidth := Max(1, AvailableWidth);
  AvailableHeight := Max(1, AvailableHeight);

  if (FLastAvailableWidth <> AvailableWidth) or (FLastAvailableHeight <> AvailableHeight) then
    Clear;
  FLastAvailableWidth := AvailableWidth;
  FLastAvailableHeight := AvailableHeight;

  if Options.KeepAspectRatio then
  begin
    var ScaleX := AvailableWidth / Bitmap.Width;
    var ScaleY := (AvailableHeight * 2.0) / Bitmap.Height;
    var Scale := Min(ScaleX, ScaleY);

    TargetWidth := Max(1, Min(AvailableWidth, Floor(Bitmap.Width * Scale)));
    TargetPixelHeight := Max(2, Min(AvailableHeight * 2, Floor(Bitmap.Height * Scale)));

    if Odd(TargetPixelHeight) then
      Inc(TargetPixelHeight);

    TargetRows := Min(AvailableHeight, TargetPixelHeight div 2);
  end
  else
  begin
    TargetWidth := AvailableWidth;
    TargetRows := AvailableHeight;
    TargetPixelHeight := TargetRows * 2;
  end;

  var Builder := TStringBuilder.Create(TargetWidth * TargetRows * 6);
  try
    for var PY := 0 to TargetRows - 1 do
    begin
      Builder.Append(#27'[');
      Builder.Append(Options.Y + PY);
      Builder.Append(';');
      Builder.Append(Options.X);
      Builder.Append('H');

      var PrevFR: Integer := -1;
      var PrevFG: Integer := -1;
      var PrevFB: Integer := -1;
      var PrevBR: Integer := -1;
      var PrevBG: Integer := -1;
      var PrevBB: Integer := -1;

      for var PX := 0 to TargetWidth - 1 do
      begin
        var SX := EnsureRange(Floor((PX + 0.5) * Bitmap.Width / TargetWidth), 0, Bitmap.Width - 1);
        var SY1 := EnsureRange(Floor((PY * 2 + 0.5) * Bitmap.Height / TargetPixelHeight), 0, Bitmap.Height - 1);
        var SY2 := EnsureRange(Floor((PY * 2 + 1.5) * Bitmap.Height / TargetPixelHeight), 0, Bitmap.Height - 1);

        var TopColor := Bitmap.Pixels[SY1 * Bitmap.Width + SX];
        var BottomColor := Bitmap.Pixels[SY2 * Bitmap.Width + SX];

        var TopR := ColorR(TopColor);
        var TopG := ColorG(TopColor);
        var TopB := ColorB(TopColor);

        var BottomR := ColorR(BottomColor);
        var BottomG := ColorG(BottomColor);
        var BottomB := ColorB(BottomColor);

        if (TopR <> PrevFR) or (TopG <> PrevFG) or (TopB <> PrevFB) then
        begin
          AppendForegroundEscape(Builder, TopR, TopG, TopB);

          PrevFR := TopR;
          PrevFG := TopG;
          PrevFB := TopB;
        end;

        if (BottomR <> PrevBR) or (BottomG <> PrevBG) or (BottomB <> PrevBB) then
        begin
          AppendBackgroundEscape(Builder, BottomR, BottomG, BottomB);

          PrevBR := BottomR;
          PrevBG := BottomG;
          PrevBB := BottomB;
        end;

        Builder.Append('▀');
      end;
    end;

    Builder.Append(#27'[0m');

    WriteRaw(Builder.ToString);
  finally
    Builder.Free;
  end;
end;

class procedure TRetromulTerminal.RenderAscii(const Bitmap: TEmulatorFrame; const Options: TTerminalRenderOptions);
var
  TargetWidth: Integer;
  TargetHeight: Integer;
begin
  if FAsciiCharset.IsEmpty then
    Exit;

  var AvailableWidth := IfThen(Options.MaxWidth > 0, Options.MaxWidth, Width - Options.X + 1);
  var AvailableHeight := IfThen(Options.MaxHeight > 0, Options.MaxHeight, Height - Options.Y + 1);

  AvailableWidth := Max(1, AvailableWidth);
  AvailableHeight := Max(1, AvailableHeight);

  if (FLastAvailableWidth <> AvailableWidth) or (FLastAvailableHeight <> AvailableHeight) then
    Clear;
  FLastAvailableWidth := AvailableWidth;
  FLastAvailableHeight := AvailableHeight;

  CalculateTargetSize(Bitmap.Width, Bitmap.Height, AvailableWidth, AvailableHeight, Options.CharacterAspect, Options.KeepAspectRatio, TargetWidth, TargetHeight);

  var Builder := TStringBuilder.Create(TargetWidth * TargetHeight * 5);
  try
    for var CY := 0 to TargetHeight - 1 do
    begin
      Builder.Append(#27'[');
      Builder.Append(Options.Y + CY);
      Builder.Append(';');
      Builder.Append(Options.X);
      Builder.Append('H');

      var PrevR: Integer := -1;
      var PrevG: Integer := -1;
      var PrevB: Integer := -1;

      var SY1 := CY * Bitmap.Height div TargetHeight;
      var SY2 := (CY + 1) * Bitmap.Height div TargetHeight;

      if SY2 <= SY1 then
        SY2 := SY1 + 1;

      SY2 := Min(SY2, Bitmap.Height);

      for var CX := 0 to TargetWidth - 1 do
      begin
        var SX1 := CX * Bitmap.Width div TargetWidth;
        var SX2 := (CX + 1) * Bitmap.Width div TargetWidth;

        if SX2 <= SX1 then
          SX2 := SX1 + 1;

        SX2 := Min(SX2, Bitmap.Width);

        var SumR: UInt64 := 0;
        var SumG: UInt64 := 0;
        var SumB: UInt64 := 0;
        var Count: UInt64 := 0;

        for var SY := SY1 to SY2 - 1 do
          for var SX := SX1 to SX2 - 1 do
          begin
            var Pixel := TAlphaColorRec(Bitmap.Pixels[SY * Bitmap.Width + SX]);
            Inc(SumR, Pixel.R);
            Inc(SumG, Pixel.G);
            Inc(SumB, Pixel.B);
            Inc(Count);
          end;

        if Count = 0 then
          Continue;

        var R := SumR div Count;
        var G := SumG div Count;
        var B := SumB div Count;

        var Brightness := Luma(R, G, B);
        if Brightness <= Options.BlackThreshold then
        begin
          Builder.Append(' ');
          Continue;
        end;

        var Index := 1 + MulDiv(Brightness, Length(FAsciiCharset) - 1, 255);
        Index := EnsureRange(Index, 1, Length(FAsciiCharset));

        var Ch := FAsciiCharset[Index];

        if (R <> PrevR) or (G <> PrevG) or (B <> PrevB) then
        begin
          AppendForegroundEscape(Builder, R, G, B);

          PrevR := R;
          PrevG := G;
          PrevB := B;
        end;

        Builder.Append(Ch);
      end;
    end;

    Builder.Append(#27'[0m');

    WriteRaw(Builder.ToString);
  finally
    Builder.Free;
  end;
end;

class function TRetromulTerminal.PollKey(out Key: TTerminalKey): Boolean;
var
  Event: TInputRecord;
  Count: DWORD;
begin
  Result := False;
  Key := TTerminalKey.Empty;

  if not FInitialized then
    Initialize;

  while True do
  begin
    if not PeekConsoleInputW(FInputHandle, Event, 1, Count) then
      Exit;
    if Count = 0 then
      Exit;
    if not ReadConsoleInputW(FInputHandle, Event, 1, Count) then
      Exit;
    if Event.EventType <> KEY_EVENT then
      Continue;

    Key.VirtualKey := Event.Event.KeyEvent.wVirtualKeyCode;
    Key.Character := Event.Event.KeyEvent.UnicodeChar;
    Key.KeyDown := Event.Event.KeyEvent.bKeyDown;
    Key.RepeatCount := Event.Event.KeyEvent.wRepeatCount;
    var State := Event.Event.KeyEvent.dwControlKeyState;
    Key.Shift := (State and SHIFT_PRESSED) <> 0;
    Key.Ctrl := (State and (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
    Key.Alt := (State and (LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED)) <> 0;

    Exit(True);
  end;
end;

class procedure TRetromulTerminal.FlushInput;
begin
  if not FInitialized then
    Initialize;

  FlushConsoleInputBuffer(FInputHandle);
end;

class function TRetromulTerminal.GetVirtualKeyState(const VirtualKey: Integer): Boolean;
begin
  Result := (Winapi.Windows.GetAsyncKeyState(VirtualKey) and $8000) <> 0;
end;

class function TRetromulTerminal.IsKeyDown(const VirtualKey: Integer): Boolean;
begin
  Result := GetVirtualKeyState(VirtualKey);
end;

class function TRetromulTerminal.IsKeyDown(const Key: Char): Boolean;
begin
  var VK := VkKeyScanW(Key);

  if VK = -1 then
    Exit(False);

  Result := GetVirtualKeyState(VK and $FF);
end;

class function TRetromulTerminal.IsKeyPressed(const VirtualKey: Integer): Boolean;
begin
  Result := (Winapi.Windows.GetAsyncKeyState(VirtualKey) and $0001) <> 0;
end;

class procedure TRetromulTerminal.SetAsciiCharset(const Value: string);
begin
  if Value.IsEmpty then
    FAsciiCharset := DEFAULT_ASCII_CHARSET
  else
    FAsciiCharset := Value;
end;

end.


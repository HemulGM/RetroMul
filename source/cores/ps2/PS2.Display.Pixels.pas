unit PS2.Display.Pixels;

{$POINTERMATH ON}
interface

uses
  System.SysUtils, Core.Emulation.Types;

type
  TPixelBank<T> = record
  private
    FSlots: array[0..3] of TArray<T>;
  public
    function Acquire(Count: Integer): TArray<T>;
  end;

procedure DisplayAlpha(Source, Dest: PCardinal; Count: Integer; Small: Boolean);

procedure DisplayRGB(Source, Dest: PCardinal; Count: Integer);

const
  DisplayRows = True;

implementation

function TPixelBank<T>.Acquire(Count: Integer): TArray<T>;
begin
  var Spare := -1;
  for var I := 0 to High(FSlots) do
    if (FSlots[I] = nil) or (EmulationBufferReferences(Pointer(FSlots[I])) = 1) then
    begin
      if Length(FSlots[I]) = Count then
        Exit(FSlots[I]);
      if Spare < 0 then
        Spare := I;
    end;
  // The published arrays may still be observed. Releasing our reference
  // never makes someone else's array writable.
  if Spare < 0 then
    Spare := 0;
  FSlots[Spare] := nil;
  SetLength(FSlots[Spare], Count);
  Result := FSlots[Spare];
end;

{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
procedure Alpha4(Source, Dest: PCardinal; Groups: Integer; Small: Boolean);
asm
        .       NOFRAME
        mov     eax, $00FFFFFF
        mov     r10d, $80000000
        test    r9b, r9b
        jz      @@Ready
        OR      eax, r10d
        XOR     r10d, r10d

@@Ready:
        movd    xmm1, eax
        pshufd  xmm1, xmm1, 0
        movd    xmm2, r10d
        pshufd  xmm2, xmm2, 0

@@Loop:
        movdqu  xmm0, [rcx]
        pand    xmm0, xmm1
        por     xmm0, xmm2
        movdqu  [rdx], xmm0
        add     rcx, 16
        add     rdx, 16
        dec     r8d
        jnz     @@Loop
end;

procedure RGB4(Source, Dest: PCardinal; Groups: Integer);
asm
        .       NOFRAME
        mov     eax, $00FF00FF
        movd    xmm2, eax
        pshufd  xmm2, xmm2, 0
        mov     eax, $FF000000
        movd    xmm3, eax
        pshufd  xmm3, xmm3, 0

@@Loop:
        movdqu  xmm0, [rcx]
        pshuflw xmm1, xmm0, $B1
        pshufhw xmm1, xmm1, $B1
        pxor    xmm1, xmm0
        pand    xmm1, xmm2
        pxor    xmm0, xmm1
        por     xmm0, xmm3
        movdqu  [rdx], xmm0
        add     rcx, 16
        add     rdx, 16
        dec     r8d
        jnz     @@Loop
end;
{$ENDIF}

procedure DisplayAlpha(Source, Dest: PCardinal; Count: Integer; Small: Boolean);
begin
  var Start := 0;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  if Count >= 4 then
  begin
    Alpha4(Source, Dest, Count div 4, Small);
    Start := Count and  - 4;
  end;
{$ENDIF}
  for var I := Start to Count - 1 do
    if Small then
      Dest[I] := Source[I] and $80FFFFFF
    else
      Dest[I] := (Source[I] and $FFFFFF) or $80000000;
end;

procedure DisplayRGB(Source, Dest: PCardinal; Count: Integer);
begin
  var Start := 0;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  if Count >= 4 then
  begin
    RGB4(Source, Dest, Count div 4);
    Start := Count and  - 4;
  end;
{$ENDIF}
  for var I := Start to Count - 1 do
  begin
    var C := Source[I];
    Dest[I] := $FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF);
  end;
end;

end.


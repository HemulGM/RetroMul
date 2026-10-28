unit GW.Artwork;

interface

uses
  System.SysUtils, System.UITypes;

type
  TGWLayer = record
    Index, X, Y, Width, Height: Integer;
    Pixels: TArray<TAlphaColor>;
  end;

  TGWArtwork = record
    Width, Height: Integer;
    Background: TArray<TAlphaColor>;
    Layers: TArray<TGWLayer>;
  end;

  // The frontend supplies image decoding; cartridge parsing has no FMX dependency.
  IGWArtworkRenderer = interface
    ['{F62CBD5F-D4D2-43E2-B243-80AB1FEA082F}']
    function Render(const Screens: TArray<string>; Layout: Integer; ShiftLCD: Boolean): TGWArtwork;
    function DecodeBitmap(const Data: TBytes; Width, Height: Integer): TArray<TAlphaColor>;
  end;

procedure SetDefaultGWArtworkRenderer(const Renderer: IGWArtworkRenderer);

function DefaultGWArtworkRenderer: IGWArtworkRenderer;

implementation

var
  FDefaultRenderer: IGWArtworkRenderer;

procedure SetDefaultGWArtworkRenderer(const Renderer: IGWArtworkRenderer);
begin
  FDefaultRenderer := Renderer;
end;

function DefaultGWArtworkRenderer: IGWArtworkRenderer;
begin
  Result := FDefaultRenderer;
end;

end.


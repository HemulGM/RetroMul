unit MD.VDP;

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

{$Q-}
{$R-}

type
  TVDPConfiguration = record
    c_sprites_disabled: Byte;
    c_window_disabled: Byte;
    c_planes_disabled: array[0..1] of Byte;
    c_widescreen_tiles: Byte;
  end;

  TVDPTileMetadata = record
    c_tile_index: Cardinal;
    c_palette_line: Cardinal;
    c_x_flip: Byte;
    c_y_flip: Byte;
    c_priority: Byte;
  end;

  TVDPCachedSprite = record
    c_y: Cardinal;
    c_link: Cardinal;
    c_width: Cardinal;
    c_height: Cardinal;
  end;

  TVDPSpriteRowCacheEntry = record
    c_table_index: Byte;
    c_y_in_sprite: Byte;
    c_width: Byte;
    c_height: Byte;
  end;

  TVDPSpriteRowCacheRow = record
    c_total: Byte;
    c_sprites: array[0..31] of TVDPSpriteRowCacheEntry;
  end;

  TVDPAccessState = record
    c_write_pending: Byte;
    c_address_register: Cardinal;
    c_code_register: Word;
    c_increment: Byte;
    c_selected_buffer: Integer;
  end;

  TVDPDMAState = record
    c_enabled: Byte;
    c_mode: Integer;
    c_source_address_high: Byte;
    c_source_address_low: Word;
    c_length: Word;
  end;

  TVDPWindowState = record
    c_aligned_right: Byte;
    c_aligned_bottom: Byte;
    c_horizontal_boundary: Word;
    c_vertical_boundary: Word;
  end;

  TVDPDebugState = record
    c_selected_register: Byte;
    c_hide_layers: Byte;
    c_forced_layer: Byte;
  end;

  TVDPSpriteRowCache = record
    c_needs_updating: Byte;
    c_rows: array[0..479] of TVDPSpriteRowCacheRow;
  end;

  TVDPState = record
    c_access: TVDPAccessState;
    c_dma: TVDPDMAState;
    c_plane_a_address: Cardinal;
    c_plane_b_address: Cardinal;
    c_window_address: Cardinal;
    c_sprite_table_address: Cardinal;
    c_hscroll_address: Cardinal;
    c_window: TVDPWindowState;
    c_plane_width_shift: Byte;
    c_plane_height_bitmask: Byte;
    c_extended_vram_enabled: Byte;
    c_display_enabled: Byte;
    c_v_int_enabled: Byte;
    c_h_int_enabled: Byte;
    c_h40_enabled: Byte;
    c_v30_enabled: Byte;
    c_mega_drive_mode_enabled: Byte;
    c_shadow_highlight_enabled: Byte;
    c_double_resolution_enabled: Byte;
    c_sprite_tile_index_rebase: Byte;
    c_plane_a_tile_index_rebase: Byte;
    c_plane_b_tile_index_rebase: Byte;
    c_background_colour: Byte;
    c_h_int_interval: Byte;
    c_currently_in_vblank: Byte;
    c_allow_sprite_masking: Byte;
    c_hscroll_mask: Byte;
    c_vscroll_mode: Integer;
    c_debug: TVDPDebugState;
    c_vram: array[0..65535] of Byte;
    c_cram: array[0..63] of Word;
    c_vsram: array[0..63] of Word;
    c_vsram_cache: array[0..1] of Word;
    c_sprite_table_cache: array[0..127] of array[0..3] of Byte;
    c_sprite_row_cache: TVDPSpriteRowCache;
    c_previous_data_writes: array[0..3] of Word;
    c_kdebug_buffer_index: Word;
    c_kdebug_buffer: array[0..255] of Byte;
  end;

  TVDP = record
    c_configuration: TVDPConfiguration;
    c_state: TVDPState;
  end;

  TVDPScanlineRenderedCallback = procedure(c_user_data: Pointer; c_scanline: Cardinal; const c_pixels: array of Byte; PixelOffset: Integer; c_left_boundary: Cardinal; c_right_boundary: Cardinal; c_screen_width: Cardinal; c_screen_height: Cardinal);

  TVDPColourUpdatedCallback = procedure(c_user_data: Pointer; c_index: Cardinal; c_colour: Cardinal);

  TVDPDMATransferBeginCallback = procedure(c_user_data: Pointer; c_total_reads: Cardinal; c_target_cycle: Cardinal);

  TVDPReadCallback = function(c_user_data: Pointer; c_address: Cardinal; c_target_cycle: Cardinal): Cardinal;

  TVDPKDebugCallback = procedure(c_user_data: Pointer; c_string: PByte);

  TBlitLookupLower = record
    c_pixels: array[0..255] of Byte;
  end;

  TBlitLookup = record
    c_lower: array[0..127] of TBlitLookupLower;
  end;

  TBlitLookupTables = record
    c_normal: TBlitLookup;
    c_shadow_highlight: TBlitLookup;
    c_forced_layer: TBlitLookup;
  end;

  PVDPState = ^TVDPState;

  PVDP = ^TVDP;

  PBlitLookup = ^TBlitLookup;

  PVDPSpriteRowCacheRow = ^TVDPSpriteRowCacheRow;

  PVDPSpriteRowCacheEntry = ^TVDPSpriteRowCacheEntry;

const
  c_VDP_ACCESS_VRAM = ( -1) + 1;
  c_VDP_ACCESS_CRAM = ( c_VDP_ACCESS_VRAM) + 1;
  c_VDP_ACCESS_VSRAM = ( c_VDP_ACCESS_CRAM) + 1;
  c_VDP_ACCESS_VRAM_8BIT = ( c_VDP_ACCESS_VSRAM) + 1;
  c_VDP_ACCESS_INVALID = ( c_VDP_ACCESS_VRAM_8BIT) + 1;
  c_VDP_DMA_MODE_MEMORY_TO_VRAM = ( -1) + 1;
  c_VDP_DMA_MODE_FILL = ( c_VDP_DMA_MODE_MEMORY_TO_VRAM) + 1;
  c_VDP_DMA_MODE_COPY = ( c_VDP_DMA_MODE_FILL) + 1;
  c_VDP_HSCROLL_MODE_FULL = ( -1) + 1;
  c_VDP_HSCROLL_MODE_INVALID = ( c_VDP_HSCROLL_MODE_FULL) + 1;
  c_VDP_HSCROLL_MODE_1CELL = ( c_VDP_HSCROLL_MODE_INVALID) + 1;
  c_VDP_HSCROLL_MODE_1LINE = ( c_VDP_HSCROLL_MODE_1CELL) + 1;
  c_VDP_VSCROLL_MODE_FULL = ( -1) + 1;
  c_VDP_VSCROLL_MODE_2CELL = ( c_VDP_VSCROLL_MODE_FULL) + 1;
  c_SHADOW_HIGHLIGHT_NORMAL = ( 0 shl 6);
  c_SHADOW_HIGHLIGHT_SHADOW = ( 1 shl 6);
  c_SHADOW_HIGHLIGHT_HIGHLIGHT = ( 2 shl 6);

function c_IsDMAPending(c_state: PVDPState): Byte;

procedure c_ClearDMAPending(c_state: PVDPState);

function c_IsInReadMode(c_state: PVDPState): Byte;

procedure c_SetHScrollMode(c_state: PVDPState; c_mode: Integer);

function c_GetSpriteTableAddress(c_state: PVDPState): Cardinal;

function c_GetWindowPlaneTableAddress(c_state: PVDPState): Cardinal;

function c_DecodeVRAMAddress(c_state: PVDPState; c_address: Cardinal): Cardinal;

function c_ReadVRAM(c_state: PVDPState; c_address: Cardinal): Cardinal;

procedure c_WriteVRAM(c_vdp_: PVDP; c_address: Cardinal; c_value: Cardinal);

procedure c_IncrementAccessAddressRegister(c_state: PVDPState);

procedure c_WriteAndIncrement(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer);

function c_ReadAndIncrement(c_state: PVDPState): Cardinal;

procedure c_VDP_Constant_Initialise();

procedure c_VDP_Initialise(c_vdp_: PVDP);

function c_GetHScrollTableOffset(c_state: PVDPState; c_scanline: Cardinal): Cardinal;

function c_GetVScrollValue(c_vdp_: PVDP; c_plane_index: Cardinal; c_tile_pair: Cardinal): Cardinal;

procedure c_RenderTilePair(c_vdp_: PVDP; c_pixel_y_in_plane: Cardinal; c_vram_address: Cardinal; c_base_tile_vram_address: Cardinal; var c_metapixels: array of Byte; var PixelIndex: Integer; c_blit_lookup_list: PBlitLookup);

procedure c_RenderScrollingPlane(c_vdp_: PVDP; c_start: Cardinal; c_end: Cardinal; c_scanline: Cardinal; c_plane_index: Cardinal; c_plane_x_offset: Cardinal; PixelOffset: Integer; var c_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup);

procedure c_RenderWindowPlane(c_vdp_: PVDP; c_start: Cardinal; c_end: Cardinal; c_scanline: Cardinal; var c_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup);

procedure c_UpdateSpriteCache(c_vdp_: PVDP);

procedure c_RenderSprites(c_vdp_: PVDP; var c_sprite_metapixels: array of Byte; c_scanline: Cardinal);

procedure c_RenderScrollPlane(c_vdp_: PVDP; c_left_boundary: Cardinal; c_right_boundary: Cardinal; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_plane_index: Cardinal);

procedure c_RenderForegroundPlane(c_vdp_: PVDP; c_left_boundary: Cardinal; c_right_boundary: Cardinal; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_window_plane: Byte);

procedure c_RenderSpritePlane(var c_plane_metapixels: array of Byte; var c_sprite_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_mask: Cardinal; c_left_boundary_pixels: Cardinal; c_right_boundary_pixels: Cardinal);

procedure c_RenderForegroundAndSpritePlanes(c_vdp_: PVDP; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; var c_sprite_metapixels: array of Byte; c_window_plane: Byte; c_scanline_rendered_callback: TVDPScanlineRenderedCallback; c_scanline_rendered_callback_user_data: Pointer);

procedure c_VDP_BeginScanline(c_vdp_: PVDP);

procedure c_VDP_EndScanline(c_vdp_: PVDP; c_scanline: Cardinal; c_scanline_rendered_callback: TVDPScanlineRenderedCallback; c_scanline_rendered_callback_user_data: Pointer);

function c_VDP_ReadData(c_vdp_: PVDP): Cardinal;

function c_VDP_ReadControl(c_vdp_: PVDP): Cardinal;

procedure c_UpdateFakeFIFO(c_state: PVDPState; c_value: Cardinal);

procedure c_VDP_WriteData(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer);

procedure c_VDP_WriteControl(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer; c_dma_transfer_begin_callback: TVDPDMATransferBeginCallback; c_read_callback: TVDPReadCallback; c_read_callback_user_data: Pointer; c_kdebug_callback: TVDPKDebugCallback; c_kdebug_callback_user_data: Pointer; c_target_cycle: Cardinal);

procedure c_VDP_WriteDebugData(c_vdp_: PVDP; c_value: Cardinal);

procedure c_VDP_WriteDebugControl(c_vdp_: PVDP; c_value: Cardinal);

function c_VDP_ReadVRAMWord(c_state: PVDPState; c_address: Cardinal): Cardinal;

function c_VDP_DecomposeTileMetadata(c_packed_tile_metadata: Cardinal): TVDPTileMetadata;

function c_VDP_GetCachedSprite(c_state: PVDPState; c_sprite_index: Cardinal): TVDPCachedSprite;

implementation

const
  PlanePadding = 16;
  SpritePadding = 31;

var
  c_blit_lookup: TBlitLookupTables;

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer((Cardinal(Value) shr Bits) or (Cardinal(-Ord(Value < 0)) shl (32 - Bits)));
end;

function c_IsDMAPending(c_state: PVDPState): Byte;
begin
  Exit(Byte(Ord(Integer(c_state^.c_access.c_code_register and $20) <> Integer(0))));
end;

procedure c_ClearDMAPending(c_state: PVDPState);
begin
  c_state^.c_access.c_code_register := Word(c_state^.c_access.c_code_register and (not $20));
end;

function c_IsInReadMode(c_state: PVDPState): Byte;
begin
  Exit(Byte(Ord(Integer(c_state^.c_access.c_code_register and 1) = Integer(0))));
end;

procedure c_SetHScrollMode(c_state: PVDPState; c_mode: Integer);
const
  c_masks: array[0..3] of Byte = ($00, $07, $F8, $FF);
begin
  c_state^.c_hscroll_mask := Byte(c_masks[Cardinal(c_mode)]);
end;

function c_GetSpriteTableAddress(c_state: PVDPState): Cardinal;
begin
  Exit(Cardinal(Cardinal(c_state^.c_sprite_table_address) and Cardinal((not Cardinal($1FF)) shl c_state^.c_h40_enabled)));
end;

function c_GetWindowPlaneTableAddress(c_state: PVDPState): Cardinal;
begin
  Exit(Cardinal(Cardinal(c_state^.c_window_address) and Cardinal((not Cardinal($7FF)) shl c_state^.c_h40_enabled)));
end;

function c_DecodeVRAMAddress(c_state: PVDPState; c_address: Cardinal): Cardinal;
begin
  if (c_state^.c_extended_vram_enabled <> 0) then
  begin
    c_address := Cardinal(Cardinal(Cardinal(Cardinal((Cardinal(c_address) and Cardinal($1F802)) shr 1) or Cardinal((Cardinal(c_address) and Cardinal($400)) shr 9)) or Cardinal(Cardinal(c_address) and Cardinal($3FC))) or Cardinal((Cardinal(c_address) and Cardinal(1)) shl 16));
  end
  else
  begin
    c_address := Cardinal(Cardinal(c_address) and Cardinal($FFFF));
  end;
  Exit(Cardinal(Cardinal(c_address) xor Cardinal(1)));
end;

function c_ReadVRAM(c_state: PVDPState; c_address: Cardinal): Cardinal;
begin
  Exit(Cardinal(c_state^.c_vram[(Cardinal(c_DecodeVRAMAddress(c_state, c_address)) mod Cardinal(Length(c_state^.c_vram)))]));
end;

procedure c_WriteVRAM(c_vdp_: PVDP; c_address: Cardinal; c_value: Cardinal);
var
  c_state: PVDPState;
  c_decoded_address: Cardinal;
  c_sprite_table_index: Cardinal;
  temp30: Integer;
  temp31: Integer;
begin
  c_state := @c_vdp_^.c_state;
  c_decoded_address := Cardinal(c_DecodeVRAMAddress(c_state, c_address));
  c_sprite_table_index := Cardinal(Sub32(c_address, c_GetSpriteTableAddress(c_state)));
  if (c_vdp_^.c_state.c_h40_enabled <> 0) then
  begin
    temp31 := 20;
  end
  else
  begin
    temp31 := 16;
  end;
  temp30 := Ord(Cardinal(c_sprite_table_index) < Cardinal(Mul32(Mul32(Mul32(Add32(temp31, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)), 2), 2), 8)));
  if temp30 <> 0 then
  begin
    temp30 := Ord(Cardinal(Cardinal(c_sprite_table_index) and Cardinal(4)) = Cardinal(0));
  end;
  if (temp30 <> 0) then
  begin

    c_state^.c_sprite_table_cache[c_sprite_table_index div 8][c_sprite_table_index and 3] := Byte(c_value);
    c_state^.c_sprite_row_cache.c_needs_updating := Byte(1);
  end;
  if (Cardinal(c_decoded_address) < Cardinal(Length(c_state^.c_vram))) then
  begin
    c_state^.c_vram[c_decoded_address] := Byte(c_value);
  end;
end;

procedure c_IncrementAccessAddressRegister(c_state: PVDPState);
begin
  c_state^.c_access.c_address_register := Cardinal(Add32(c_state^.c_access.c_address_register, c_state^.c_access.c_increment));
  c_state^.c_access.c_address_register := Cardinal(Cardinal(c_state^.c_access.c_address_register) and Cardinal($1FFFF));
end;

procedure c_WriteAndIncrement(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer);
var
  c_state: PVDPState;
  c_colour: Cardinal;
  c_index_wrapped: Cardinal;
  c_limit: Cardinal;
  c_index_wrapped_scope32: Cardinal;
  c_vscroll: Word;
  c_i: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  case c_state^.c_access.c_selected_buffer of
    c_VDP_ACCESS_VRAM:
      begin
        c_WriteVRAM(c_vdp_, (Cardinal(c_state^.c_access.c_address_register) xor Cardinal(0)), Cardinal(Cardinal(c_value) and Cardinal($FF)));
        c_WriteVRAM(c_vdp_, (Cardinal(c_state^.c_access.c_address_register) xor Cardinal(1)), Cardinal(c_value shr 8));
      end;
    c_VDP_ACCESS_CRAM:
      begin
        c_colour := Cardinal(Cardinal(c_value) and Cardinal($EEE));
        c_index_wrapped := Cardinal(Cardinal(Cardinal(c_state^.c_access.c_address_register) div Cardinal(2)) mod Cardinal(Length(c_state^.c_cram)));
        c_state^.c_cram[c_index_wrapped] := Word(c_colour);
        c_colour_updated_callback(Pointer(c_colour_updated_callback_user_data), (Add32(c_SHADOW_HIGHLIGHT_NORMAL, c_index_wrapped)), (Cardinal(c_colour) or Cardinal((Cardinal(c_colour) and Cardinal($888)) shr 3)));
        c_colour_updated_callback(Pointer(c_colour_updated_callback_user_data), (Add32(c_SHADOW_HIGHLIGHT_SHADOW, c_index_wrapped)), (c_colour shr 1));
        c_colour_updated_callback(Pointer(c_colour_updated_callback_user_data), (Add32(c_SHADOW_HIGHLIGHT_HIGHLIGHT, c_index_wrapped)), (Add32($888, c_colour shr 1)));
      end;
    c_VDP_ACCESS_VSRAM:
      begin
        c_limit := Cardinal(40);
        c_index_wrapped_scope32 := Cardinal(Cardinal(Cardinal(c_state^.c_access.c_address_register) div Cardinal(2)) mod Cardinal(Length(c_state^.c_vsram)));
        if (Cardinal(c_index_wrapped_scope32) < Cardinal(c_limit)) then
        begin
          c_vscroll := Word(Word(Cardinal(c_value) and Cardinal($7FF)));
          if (Cardinal(c_index_wrapped_scope32) < Cardinal(2)) then
          begin
            c_i := Cardinal(Add32(c_limit, c_index_wrapped_scope32));
            while (Cardinal(c_i) < Cardinal(Length(c_state^.c_vsram))) do
            begin
              c_state^.c_vsram[c_i] := Word(c_vscroll);
              c_i := Cardinal(Add32(c_i, 2));
            end;
          end;
          c_state^.c_vsram[c_index_wrapped_scope32] := Word(c_vscroll);
        end;
      end;
    c_VDP_ACCESS_INVALID, c_VDP_ACCESS_VRAM_8BIT:
      begin
        ;
      end;
  else
    begin
      Assert(0 <> 0);
      ;
    end;
  end;
  c_IncrementAccessAddressRegister(c_state);
end;

function c_ReadAndIncrement(c_state: PVDPState): Cardinal;
begin
  var c_word_address: Cardinal := Cardinal(Cardinal(c_state^.c_access.c_address_register) div Cardinal(2));
  var c_value: Cardinal := c_state^.c_previous_data_writes[0];
  case c_state^.c_access.c_selected_buffer of
    c_VDP_ACCESS_VRAM:
      begin
        c_value := Cardinal(Cardinal(c_ReadVRAM(c_state, (Cardinal(Mul32(c_word_address, 2)) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(Mul32(c_word_address, 2)) xor Cardinal(1))) shl 8));
      end;
    c_VDP_ACCESS_CRAM:
      begin
        c_value := Cardinal(Cardinal(c_value) and Cardinal(not $EEE));
        c_value := Cardinal(Cardinal(c_value) or Cardinal(c_state^.c_cram[(Cardinal(c_word_address) mod Cardinal(Length(c_state^.c_cram)))]));
      end;
    c_VDP_ACCESS_VSRAM:
      begin
        c_value := Cardinal(Cardinal(c_value) and Cardinal(not $7FF));
        c_value := Cardinal(Cardinal(c_value) or Cardinal(c_state^.c_vsram[(Cardinal(c_word_address) mod Cardinal(Length(c_state^.c_vsram)))]));
      end;
    c_VDP_ACCESS_VRAM_8BIT:
      begin
        c_value := Cardinal(Cardinal(c_value) and Cardinal(not $FF));
        c_value := Cardinal(Cardinal(c_value) or Cardinal(c_ReadVRAM(c_state, c_state^.c_access.c_address_register)));
      end;
    c_VDP_ACCESS_INVALID:
      begin
        ;
      end;
  else
    begin
      Assert(0 <> 0);
      ;
    end;
  end;
  c_IncrementAccessAddressRegister(c_state);
  Exit(Cardinal(c_value));
end;

procedure c_VDP_Constant_Initialise();
var
  c_old_pixel: Cardinal;
  c_palette_line_index_mask: Cardinal;
  c_colour_index_mask: Cardinal;
  c_priority_mask: Cardinal;
  c_not_shadowed_mask: Cardinal;
  c_old_palette_line_index: Cardinal;
  c_old_colour_index: Cardinal;
  c_old_priority: Byte;
  c_old_not_shadowed: Byte;
  c_new_palette_line_index: Cardinal;
  c_new_colour_index: Cardinal;
  c_new_priority: Byte;
  c_new_not_shadowed: Byte;
  c_draw_new_pixel: Byte;
  temp53: Integer;
  temp54: Integer;
  temp55: Integer;
  c_output: Cardinal;
  temp56: Cardinal;
  temp57: Cardinal;
  temp58: Integer;
  temp66: Integer;
  temp67: Integer;
  temp68: Integer;
  temp69: Integer;
begin
  var c_new_pixel: Cardinal := 0;
  while (Cardinal(c_new_pixel) < Cardinal(Length(c_blit_lookup.c_normal.c_lower))) do
  begin
    c_old_pixel := Cardinal(0);
    while (Cardinal(c_old_pixel) < Cardinal(Length(c_blit_lookup.c_normal.c_lower[0].c_pixels))) do
    begin
      c_palette_line_index_mask := Cardinal($F);
      c_colour_index_mask := Cardinal($3F);
      c_priority_mask := Cardinal($40);
      c_not_shadowed_mask := Cardinal($80);
      c_old_palette_line_index := Cardinal(Cardinal(c_old_pixel) and Cardinal(c_palette_line_index_mask));
      c_old_colour_index := Cardinal(Cardinal(c_old_pixel) and Cardinal(c_colour_index_mask));
      c_old_priority := Byte(Ord(Cardinal(Cardinal(c_old_pixel) and Cardinal(c_priority_mask)) <> Cardinal(0)));
      c_old_not_shadowed := Byte(Ord(Cardinal(Cardinal(c_old_pixel) and Cardinal(c_not_shadowed_mask)) <> Cardinal(0)));
      c_new_palette_line_index := Cardinal(Cardinal(c_new_pixel) and Cardinal(c_palette_line_index_mask));
      c_new_colour_index := Cardinal(Cardinal(c_new_pixel) and Cardinal(c_colour_index_mask));
      c_new_priority := Byte(Ord(Cardinal(Cardinal(c_new_pixel) and Cardinal(c_priority_mask)) <> Cardinal(0)));
      c_new_not_shadowed := Byte(c_new_priority);
      temp53 := Ord(Cardinal(c_new_palette_line_index) <> Cardinal(0));
      if temp53 <> 0 then
      begin
        temp55 := Ord(Cardinal(c_old_palette_line_index) = Cardinal(0));
        if temp55 = 0 then
        begin
          temp55 := Ord(not (c_old_priority <> 0));
        end;
        temp54 := Ord(temp55 <> 0);
        if temp54 = 0 then
        begin
          temp54 := Ord(c_new_priority <> 0);
        end;
        temp53 := Ord(temp54 <> 0);
      end;
      c_draw_new_pixel := Byte(temp53);
      if (c_draw_new_pixel <> 0) then
      begin
        temp56 := c_new_pixel;
      end
      else
      begin
        temp56 := c_old_pixel;
      end;
      c_output := Cardinal(temp56);
      temp58 := Ord(c_old_not_shadowed <> 0);
      if temp58 = 0 then
      begin
        temp58 := Ord(c_new_not_shadowed <> 0);
      end;
      if (temp58 <> 0) then
      begin
        temp57 := c_not_shadowed_mask;
      end
      else
      begin
        temp57 := 0;
      end;
      c_output := Cardinal(Cardinal(c_output) or Cardinal(temp57));
      c_blit_lookup.c_normal.c_lower[c_new_pixel].c_pixels[c_old_pixel] := Byte(Byte(c_output));
      if (c_draw_new_pixel <> 0) then
      begin
        case c_new_colour_index of
          $0E, $1E, $2E:
            begin
              c_output := Cardinal(Cardinal(c_new_colour_index) or Cardinal(c_SHADOW_HIGHLIGHT_NORMAL));
            end;
          $3E:
            begin
              if (c_old_not_shadowed <> 0) then
              begin
                temp66 := c_SHADOW_HIGHLIGHT_HIGHLIGHT;
              end
              else
              begin
                temp66 := c_SHADOW_HIGHLIGHT_NORMAL;
              end;
              c_output := Cardinal(Cardinal(c_old_colour_index) or Cardinal(temp66));
            end;
          $3F:
            begin
              c_output := Cardinal(Cardinal(c_old_colour_index) or Cardinal(c_SHADOW_HIGHLIGHT_SHADOW));
            end;
        else
          begin
            temp68 := Ord(c_new_not_shadowed <> 0);
            if temp68 = 0 then
            begin
              temp68 := Ord(c_old_not_shadowed <> 0);
            end;
            if (temp68 <> 0) then
            begin
              temp67 := c_SHADOW_HIGHLIGHT_NORMAL;
            end
            else
            begin
              temp67 := c_SHADOW_HIGHLIGHT_SHADOW;
            end;
            c_output := Cardinal(Cardinal(c_new_colour_index) or Cardinal(temp67));
          end;
        end;
      end
      else
      begin
        if (c_old_not_shadowed <> 0) then
        begin
          temp69 := c_SHADOW_HIGHLIGHT_NORMAL;
        end
        else
        begin
          temp69 := c_SHADOW_HIGHLIGHT_SHADOW;
        end;
        c_output := Cardinal(Cardinal(c_old_colour_index) or Cardinal(temp69));
      end;
      c_blit_lookup.c_shadow_highlight.c_lower[c_new_pixel].c_pixels[c_old_pixel] := Byte(Byte(c_output));
      c_blit_lookup.c_forced_layer.c_lower[c_new_pixel].c_pixels[c_old_pixel] := Byte(Byte(Cardinal(c_old_pixel) and Cardinal(Cardinal(c_new_colour_index) or Cardinal(not c_colour_index_mask))));
      Inc(c_old_pixel);
    end;
    Inc(c_new_pixel);
  end;
end;

procedure c_VDP_Initialise(c_vdp_: PVDP);
begin
  c_vdp_^.c_state.c_access.c_write_pending := Byte(0);
  c_vdp_^.c_state.c_access.c_address_register := Cardinal(0);
  c_vdp_^.c_state.c_access.c_code_register := Word(0);
  c_vdp_^.c_state.c_access.c_selected_buffer := c_VDP_ACCESS_VRAM;
  c_vdp_^.c_state.c_access.c_increment := Byte(0);
  c_vdp_^.c_state.c_dma.c_enabled := Byte(0);
  c_vdp_^.c_state.c_dma.c_mode := c_VDP_DMA_MODE_MEMORY_TO_VRAM;
  c_vdp_^.c_state.c_dma.c_source_address_high := Byte(0);
  c_vdp_^.c_state.c_dma.c_source_address_low := Word(0);
  c_vdp_^.c_state.c_dma.c_length := Word(0);
  c_vdp_^.c_state.c_plane_a_address := Cardinal(0);
  c_vdp_^.c_state.c_plane_b_address := Cardinal(0);
  c_vdp_^.c_state.c_window_address := Cardinal(0);
  c_vdp_^.c_state.c_sprite_table_address := Cardinal(0);
  c_vdp_^.c_state.c_hscroll_address := Cardinal(0);
  c_vdp_^.c_state.c_window.c_aligned_right := Byte(0);
  c_vdp_^.c_state.c_window.c_aligned_bottom := Byte(0);
  c_vdp_^.c_state.c_window.c_horizontal_boundary := Word(0);
  c_vdp_^.c_state.c_window.c_vertical_boundary := Word(0);
  c_vdp_^.c_state.c_plane_width_shift := Byte(5);
  c_vdp_^.c_state.c_plane_height_bitmask := Byte($1F);
  c_vdp_^.c_state.c_extended_vram_enabled := Byte(0);
  c_vdp_^.c_state.c_display_enabled := Byte(0);
  c_vdp_^.c_state.c_v_int_enabled := Byte(0);
  c_vdp_^.c_state.c_h_int_enabled := Byte(0);
  c_vdp_^.c_state.c_h40_enabled := Byte(0);
  c_vdp_^.c_state.c_v30_enabled := Byte(0);
  c_vdp_^.c_state.c_mega_drive_mode_enabled := Byte(0);
  c_vdp_^.c_state.c_shadow_highlight_enabled := Byte(0);
  c_vdp_^.c_state.c_double_resolution_enabled := Byte(0);
  c_vdp_^.c_state.c_sprite_tile_index_rebase := Byte(0);
  c_vdp_^.c_state.c_plane_a_tile_index_rebase := Byte(0);
  c_vdp_^.c_state.c_plane_b_tile_index_rebase := Byte(0);
  c_vdp_^.c_state.c_background_colour := Byte(0);
  c_vdp_^.c_state.c_h_int_interval := Byte(0);
  c_vdp_^.c_state.c_currently_in_vblank := Byte(1);
  c_vdp_^.c_state.c_allow_sprite_masking := Byte(0);
  c_SetHScrollMode(@c_vdp_^.c_state, c_VDP_HSCROLL_MODE_FULL);
  c_vdp_^.c_state.c_vscroll_mode := c_VDP_VSCROLL_MODE_FULL;
  c_vdp_^.c_state.c_debug.c_selected_register := Byte(0);
  c_vdp_^.c_state.c_debug.c_hide_layers := Byte(0);
  c_vdp_^.c_state.c_debug.c_forced_layer := Byte(0);
  FillChar(c_vdp_^.c_state.c_vram, SizeOf(c_vdp_^.c_state.c_vram), 0);
  FillChar(c_vdp_^.c_state.c_cram, SizeOf(c_vdp_^.c_state.c_cram), 0);
  FillChar(c_vdp_^.c_state.c_vsram, SizeOf(c_vdp_^.c_state.c_vsram), 0);
  FillChar(c_vdp_^.c_state.c_sprite_table_cache, SizeOf(c_vdp_^.c_state.c_sprite_table_cache), 0);
  c_vdp_^.c_state.c_sprite_row_cache.c_needs_updating := Byte(1);
  FillChar(c_vdp_^.c_state.c_sprite_row_cache.c_rows, SizeOf(c_vdp_^.c_state.c_sprite_row_cache.c_rows), 0);
  FillChar(c_vdp_^.c_state.c_previous_data_writes, SizeOf(c_vdp_^.c_state.c_previous_data_writes), 0);
  c_vdp_^.c_state.c_kdebug_buffer_index := Word(0);
  c_vdp_^.c_state.c_kdebug_buffer[(Length(c_vdp_^.c_state.c_kdebug_buffer) - 1)] := Byte(0);
end;

function c_GetHScrollTableOffset(c_state: PVDPState; c_scanline: Cardinal): Cardinal;
begin
  Exit(Cardinal(Mul32(Cardinal(c_scanline shr c_state^.c_double_resolution_enabled) and Cardinal(c_state^.c_hscroll_mask), 4)));
end;

function c_GetVScrollValue(c_vdp_: PVDP; c_plane_index: Cardinal; c_tile_pair: Cardinal): Cardinal;
var
  c_state: PVDPState;
begin
  c_state := @c_vdp_^.c_state;
  case c_state^.c_vscroll_mode of
    c_VDP_VSCROLL_MODE_FULL:
      begin
        Exit(Cardinal(c_state^.c_vsram_cache[c_plane_index]));
      end;
    c_VDP_VSCROLL_MODE_2CELL:
      begin
        Exit(Cardinal(c_state^.c_vsram[(Add32(c_plane_index, Cardinal(Mul32(Sub32(c_tile_pair, (c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2), 2)) mod Cardinal(Length(c_state^.c_vsram))))]));
      end;
  else
    begin
      Assert(0 <> 0);
      Exit(Cardinal(c_state^.c_vsram_cache[c_plane_index]));
    end;
  end;
end;

procedure c_RenderTilePair(c_vdp_: PVDP; c_pixel_y_in_plane: Cardinal; c_vram_address: Cardinal; c_base_tile_vram_address: Cardinal; var c_metapixels: array of Byte; var PixelIndex: Integer; c_blit_lookup_list: PBlitLookup);
var
  c_state: PVDPState;
  c_word_vram_address: Cardinal;
  c_word: Cardinal;
  c_x_flip: Cardinal;
  c_y_flip: Cardinal;
  c_pixel_y_in_tile: Cardinal;
  c_tile_row_vram_address: Cardinal;
  c_byte_index_xor: Cardinal;
  c_nybble_shift_2: Cardinal;
  c_nybble_shift_1: Cardinal;
  c_j: Cardinal;
  c_byte: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  var c_tile_height_shift: Cardinal := 3 + c_state^.c_double_resolution_enabled;
  var c_tile_height_mask: Cardinal := Cardinal((1 shl c_tile_height_shift) - 1);
  var c_pixel_y_in_tile_unflipped: Cardinal := Cardinal(Cardinal(c_pixel_y_in_plane) and Cardinal(c_tile_height_mask));
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(2)) do
  begin
    c_word_vram_address := Cardinal(Add32(c_vram_address, Mul32(c_i, 2)));
    c_word := Cardinal(Cardinal(c_ReadVRAM(c_state, (Cardinal(c_word_vram_address) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(c_word_vram_address) xor Cardinal(1))) shl 8));
    c_x_flip := Cardinal(-Cardinal(Ord(Cardinal(Cardinal(c_word) and Cardinal($800)) <> Cardinal(0))));
    c_y_flip := Cardinal(-Cardinal(Ord(Cardinal(Cardinal(c_word) and Cardinal($1000)) <> Cardinal(0))));
    c_pixel_y_in_tile := Cardinal(Cardinal(c_pixel_y_in_tile_unflipped) xor Cardinal(Cardinal(c_tile_height_mask) and Cardinal(c_y_flip)));
    c_tile_row_vram_address := Cardinal(Add32(c_base_tile_vram_address, (Add32((Cardinal(c_word) and Cardinal($7FF)) shl c_tile_height_shift, c_pixel_y_in_tile)) shl 2));
    c_byte_index_xor := Cardinal(Cardinal(1) xor Cardinal(Cardinal(3) and Cardinal(c_x_flip)));
    c_nybble_shift_2 := Cardinal(Cardinal(4) and Cardinal(c_x_flip));
    c_nybble_shift_1 := Cardinal(Cardinal(4) xor Cardinal(c_nybble_shift_2));
    var LookupIndex := (c_word shr 9) and $70;
    c_j := Cardinal(0);
    while (Cardinal(c_j) < Cardinal(8 div 2)) do
    begin
      c_byte := Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_tile_row_vram_address, c_j)) xor Cardinal(c_byte_index_xor))));
      c_metapixels[PixelIndex] := Byte(c_blit_lookup_list^.c_lower[LookupIndex + ((c_byte shr c_nybble_shift_1) and $F)].c_pixels[c_metapixels[PixelIndex]]);
      Inc(PixelIndex);
      c_metapixels[PixelIndex] := Byte(c_blit_lookup_list^.c_lower[LookupIndex + ((c_byte shr c_nybble_shift_2) and $F)].c_pixels[c_metapixels[PixelIndex]]);
      Inc(PixelIndex);
      Inc(c_j);
    end;
    Inc(c_i);
  end;
end;

procedure c_RenderScrollingPlane(c_vdp_: PVDP; c_start: Cardinal; c_end: Cardinal; c_scanline: Cardinal; c_plane_index: Cardinal; c_plane_x_offset: Cardinal; PixelOffset: Integer; var c_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup);
var
  c_state: PVDPState;
  temp79: Integer;
  temp80: Byte;
  c_plane_height_bitmask: Cardinal;
  temp81: Cardinal;
  temp84: Integer;
  temp85: Integer;
  temp86: Integer;
  temp87: Integer;
  c_vscroll: Cardinal;
  c_pixel_y_in_plane: Cardinal;
  c_clamped_i: Cardinal;
  temp88: Cardinal;
  c_tile_x: Cardinal;
  c_tile_y: Cardinal;
  c_vram_address: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  if (Cardinal(c_plane_index) = Cardinal(0)) then
  begin
    temp80 := c_state^.c_plane_a_tile_index_rebase;
  end
  else
  begin
    temp80 := c_state^.c_plane_b_tile_index_rebase;
  end;
  if (temp80 <> 0) then
  begin
    temp79 := $10000;
  end
  else
  begin
    temp79 := 0;
  end;
  var c_base_tile_vram_address: Cardinal := temp79;
  var c_plane_pitch_shift: Cardinal := c_state^.c_plane_width_shift;
  var c_plane_width_bitmask: Cardinal := Cardinal((1 shl c_plane_pitch_shift) - 1);
  c_plane_height_bitmask := Cardinal(c_state^.c_plane_height_bitmask);
  if (Cardinal(c_plane_index) = Cardinal(0)) then
  begin
    temp81 := c_state^.c_plane_a_address;
  end
  else
  begin
    temp81 := c_state^.c_plane_b_address;
  end;
  var c_plane_address: Cardinal := temp81;
  var c_tile_height_shift: Cardinal := 3 + c_state^.c_double_resolution_enabled;
  var PixelIndex := PixelOffset + Integer(c_start) * 16;
  var c_i: Cardinal := c_start;
  while True do
  begin
    temp84 := Ord(Cardinal(c_i) <= Cardinal(c_end));
    if temp84 <> 0 then
    begin
      if (Integer(20) > Integer(16)) then
      begin
        temp85 := 20;
      end
      else
      begin
        temp85 := 16;
      end;
      if (Integer(20) > Integer(16)) then
      begin
        temp86 := 20;
      end
      else
      begin
        temp86 := 16;
      end;
      if (Integer(20) > Integer(16)) then
      begin
        temp87 := 20;
      end
      else
      begin
        temp87 := 16;
      end;
      temp84 := Ord(Cardinal(c_i) < Cardinal(((((32 - temp85) div 2) + temp86) + ((32 - temp87) div 2)) + 1));
    end;
    if not (temp84 <> 0) then
      Break;
    c_vscroll := Cardinal(c_GetVScrollValue(c_vdp_, c_plane_index, (Sub32(c_i, 1))));
    c_pixel_y_in_plane := Cardinal(Add32(c_vscroll, c_scanline));
    if (Cardinal(c_start) > Cardinal(Sub32(c_i, 1))) then
    begin
      temp88 := c_start;
    end
    else
    begin
      temp88 := (Sub32(c_i, 1));
    end;
    c_clamped_i := Cardinal(temp88);
    c_tile_x := Cardinal(Cardinal(Mul32(Add32(c_plane_x_offset, c_clamped_i), 2)) and Cardinal(c_plane_width_bitmask));
    c_tile_y := Cardinal(Cardinal(c_pixel_y_in_plane shr c_tile_height_shift) and Cardinal(c_plane_height_bitmask));
    c_vram_address := Cardinal(Add32(c_plane_address, Mul32(Add32(c_tile_y shl c_plane_pitch_shift, c_tile_x), 2)));
    c_RenderTilePair(c_vdp_, c_pixel_y_in_plane, c_vram_address, c_base_tile_vram_address, c_metapixels, PixelIndex, c_blit_lookup_list);
    Inc(c_i);
  end;
end;

procedure c_RenderWindowPlane(c_vdp_: PVDP; c_start: Cardinal; c_end: Cardinal; c_scanline: Cardinal; var c_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup);
var
  c_state: PVDPState;
  temp89: Integer;
  temp92: Integer;
  temp93: Integer;
  temp94: Integer;
  temp95: Integer;
begin
  c_state := @c_vdp_^.c_state;
  if (c_state^.c_plane_a_tile_index_rebase <> 0) then
  begin
    temp89 := $10000;
  end
  else
  begin
    temp89 := 0;
  end;
  var c_base_tile_vram_address: Cardinal := temp89;
  var c_tile_y: Cardinal := Cardinal(c_scanline shr (3 + c_state^.c_double_resolution_enabled));
  var c_plane_pitch_shift: Cardinal := 5 + c_state^.c_h40_enabled;
  var c_plane_width_bitmask: Cardinal := Cardinal((1 shl c_plane_pitch_shift) - 1);
  var c_vram_address_base: Cardinal := Cardinal(Add32(c_GetWindowPlaneTableAddress(c_state), Mul32(c_tile_y shl c_plane_pitch_shift, 2)));
  var c_tile_x_base: Cardinal := Cardinal(Cardinal(0 - (((c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2) * 2)) and Cardinal(c_plane_width_bitmask));
  var PixelIndex := PlanePadding + Integer(c_start) * 16;
  var c_i: Cardinal := c_start;
  while True do
  begin
    temp92 := Ord(Cardinal(c_i) < Cardinal(c_end));
    if temp92 <> 0 then
    begin
      if (Integer(20) > Integer(16)) then
      begin
        temp93 := 20;
      end
      else
      begin
        temp93 := 16;
      end;
      if (Integer(20) > Integer(16)) then
      begin
        temp94 := 20;
      end
      else
      begin
        temp94 := 16;
      end;
      if (Integer(20) > Integer(16)) then
      begin
        temp95 := 20;
      end
      else
      begin
        temp95 := 16;
      end;
      temp92 := Ord(Cardinal(c_i) < Cardinal((((32 - temp93) div 2) + temp94) + ((32 - temp95) div 2)));
    end;
    if not (temp92 <> 0) then
      Break;
    c_RenderTilePair(c_vdp_, c_scanline, (Add32(c_vram_address_base, Mul32(Cardinal(Add32(c_tile_x_base, Mul32(c_i, 2))) and Cardinal(c_plane_width_bitmask), 2))), c_base_tile_vram_address, c_metapixels, PixelIndex, c_blit_lookup_list);
    Inc(c_i);
  end;
end;

procedure c_UpdateSpriteCache(c_vdp_: PVDP);
var
  c_state: PVDPState;
  temp96: Integer;
  c_cached_sprite: TVDPCachedSprite;
  c_blank_lines: Cardinal;
  temp103: Cardinal;
  temp104: Cardinal;
  temp105: Integer;
  temp106: Integer;
  c_row: PVDPSpriteRowCacheRow;
  temp108: Integer;
  c_sprite_row_cache_entry: PVDPSpriteRowCacheEntry;
  temp110: Byte;
  temp111: Integer;
begin
  c_state := @c_vdp_^.c_state;
  var c_tile_height_shift: Cardinal := 3 + c_state^.c_double_resolution_enabled;
  if (c_vdp_^.c_state.c_h40_enabled <> 0) then
  begin
    temp96 := 20;
  end
  else
  begin
    temp96 := 16;
  end;
  var c_max_sprites: Cardinal := Cardinal(Mul32(Mul32(Add32(temp96, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)), 2), 2));
  var c_sprites_remaining: Cardinal := c_max_sprites;
  if (not (c_state^.c_sprite_row_cache.c_needs_updating <> 0)) then
  begin
    Exit;
  end;
  c_state^.c_sprite_row_cache.c_needs_updating := Byte(0);
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(Length(c_state^.c_sprite_row_cache.c_rows))) do
  begin
    c_state^.c_sprite_row_cache.c_rows[c_i].c_total := Byte(0);
    Inc(c_i);
  end;
  var c_sprite_index: Cardinal := 0;
  while True do
  begin
    c_cached_sprite := c_VDP_GetCachedSprite(c_state, c_sprite_index);
    c_blank_lines := Cardinal(128 shl c_state^.c_double_resolution_enabled);
    if (Cardinal(c_blank_lines) > Cardinal(c_cached_sprite.c_y)) then
    begin
      temp103 := c_blank_lines;
    end
    else
    begin
      temp103 := c_cached_sprite.c_y;
    end;
    c_i := Cardinal(temp103);
    while True do
    begin
      if (c_state^.c_v30_enabled <> 0) then
      begin
        temp105 := 30;
      end
      else
      begin
        temp105 := 28;
      end;
      if (Cardinal(Add32(c_blank_lines, temp105 shl c_tile_height_shift)) < Cardinal(Add32(c_cached_sprite.c_y, c_cached_sprite.c_height shl c_tile_height_shift))) then
      begin
        if (c_state^.c_v30_enabled <> 0) then
        begin
          temp106 := 30;
        end
        else
        begin
          temp106 := 28;
        end;
        temp104 := (Add32(c_blank_lines, temp106 shl c_tile_height_shift));
      end
      else
      begin
        temp104 := (Add32(c_cached_sprite.c_y, c_cached_sprite.c_height shl c_tile_height_shift));
      end;
      if not (Cardinal(c_i) < Cardinal(temp104)) then
        Break;
      c_row := @c_state^.c_sprite_row_cache.c_rows[(Sub32(c_i, c_blank_lines))];
      if (c_vdp_^.c_state.c_h40_enabled <> 0) then
      begin
        temp108 := 20;
      end
      else
      begin
        temp108 := 16;
      end;
      if (Cardinal(c_row^.c_total) <> Cardinal(Add32(temp108, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)))) then
      begin
        temp110 := c_row^.c_total;
        Inc(c_row^.c_total);
        c_sprite_row_cache_entry := @c_row^.c_sprites[temp110];
        c_sprite_row_cache_entry^.c_table_index := Byte(Byte(c_sprite_index));
        c_sprite_row_cache_entry^.c_width := Byte(Byte(c_cached_sprite.c_width));
        c_sprite_row_cache_entry^.c_height := Byte(Byte(c_cached_sprite.c_height));
        c_sprite_row_cache_entry^.c_y_in_sprite := Byte(Byte(Sub32(c_i, c_cached_sprite.c_y)));
      end;
      Inc(c_i);
    end;
    if (Cardinal(c_cached_sprite.c_link) >= Cardinal(c_max_sprites)) then
    begin
      Break;
    end;
    c_sprite_index := Cardinal(c_cached_sprite.c_link);
    temp111 := Ord(Cardinal(c_sprite_index) <> Cardinal(0));
    if temp111 <> 0 then
    begin
      Dec(c_sprites_remaining);
      temp111 := Ord(Cardinal(c_sprites_remaining) <> Cardinal(0));
    end;
    if not (temp111 <> 0) then
      Break;
  end;
end;

procedure c_RenderSprites(c_vdp_: PVDP; var c_sprite_metapixels: array of Byte; c_scanline: Cardinal);
var
  c_state: PVDPState;
  temp112: Integer;
  temp113: Integer;
  c_sprite_row_cache_entry: PVDPSpriteRowCacheEntry;
  c_sprite_index: Cardinal;
  c_width: Cardinal;
  c_raw_x: Cardinal;
  c_x: Cardinal;
  temp116: Integer;
  temp117: Integer;
  temp118: Integer;
  c_height: Cardinal;
  c_word: Cardinal;
  c_sprite_tile_index: Cardinal;
  c_x_flip: Byte;
  c_y_flip: Byte;
  c_metapixel_high_bits: Cardinal;
  c_byte_index_xor: Cardinal;
  temp119: Integer;
  c_y_in_sprite_non_flipped: Cardinal;
  c_y_in_sprite: Cardinal;
  temp120: Cardinal;
  c_pixel_y_in_tile: Cardinal;
  c_nybble_shift: array[0..1] of Cardinal;
  c_j: Cardinal;
  c_x_in_sprite: Cardinal;
  temp124: Cardinal;
  c_tile_index: Cardinal;
  c_tile_row_vram_address: Cardinal;
  c_k: Cardinal;
  c_byte: Cardinal;
  c_l: Cardinal;
  c_palette_line_index: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  if (c_state^.c_sprite_tile_index_rebase <> 0) then
  begin
    temp112 := $10000;
  end
  else
  begin
    temp112 := 0;
  end;
  var c_base_tile_vram_address: Cardinal := temp112;
  var c_tile_height_shift: Cardinal := 3 + c_state^.c_double_resolution_enabled;
  var c_tile_height_mask: Cardinal := Cardinal((1 shl (3 + c_state^.c_double_resolution_enabled)) - 1);
  if (c_vdp_^.c_state.c_h40_enabled <> 0) then
  begin
    temp113 := 20;
  end
  else
  begin
    temp113 := 16;
  end;
  var c_sprite_limit: Cardinal := Cardinal(Add32(temp113, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)));
  var c_pixel_limit: Cardinal := Cardinal(Mul32(c_sprite_limit, 16));
  var c_masked: Byte := 0;
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(c_state^.c_sprite_row_cache.c_rows[c_scanline].c_total)) do
  begin
    c_sprite_row_cache_entry := @c_state^.c_sprite_row_cache.c_rows[c_scanline].c_sprites[c_i];
    c_sprite_index := Cardinal(Add32(c_GetSpriteTableAddress(c_state), c_sprite_row_cache_entry^.c_table_index * 8));
    c_width := Cardinal(c_sprite_row_cache_entry^.c_width);
    c_raw_x := Cardinal(Cardinal(Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_sprite_index, 6)) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_sprite_index, 6)) xor Cardinal(1))) shl 8)) and Cardinal($1FF));
    c_x := Cardinal(Add32(c_raw_x, (((c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2) * 2) * 8));
    if (Cardinal(c_raw_x) = Cardinal(0)) then
    begin
      c_masked := Byte(c_state^.c_allow_sprite_masking);
    end
    else
    begin
      c_state^.c_allow_sprite_masking := Byte(1);
    end;
    temp117 := Ord(c_masked <> 0);
    if temp117 = 0 then
    begin
      temp117 := Ord(Cardinal(Add32(c_x, Mul32(c_width, 8))) <= Cardinal($80));
    end;
    temp116 := Ord(temp117 <> 0);
    if temp116 = 0 then
    begin
      if (c_vdp_^.c_state.c_h40_enabled <> 0) then
      begin
        temp118 := 20;
      end
      else
      begin
        temp118 := 16;
      end;
      temp116 := Ord(Cardinal(c_x) >= Cardinal(Add32($80, Mul32(Mul32(Add32(temp118, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)), 2), 8))));
    end;
    if (temp116 <> 0) then
    begin
      if (Cardinal(c_pixel_limit) <= Cardinal(Mul32(c_width, 8))) then
      begin
        Exit;
      end;
      c_pixel_limit := Cardinal(Sub32(c_pixel_limit, Mul32(c_width, 8)));
    end
    else
    begin
      c_height := Cardinal(c_sprite_row_cache_entry^.c_height);
      c_word := Cardinal(Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_sprite_index, 4)) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_sprite_index, 4)) xor Cardinal(1))) shl 8));
      c_sprite_tile_index := Cardinal(Cardinal(c_word) and Cardinal($7FF));
      c_x_flip := Byte(Ord(Cardinal(Cardinal(c_word) and Cardinal($800)) <> Cardinal(0)));
      c_y_flip := Byte(Ord(Cardinal(Cardinal(c_word) and Cardinal($1000)) <> Cardinal(0)));
      c_metapixel_high_bits := Cardinal(Cardinal(c_word shr 9) and Cardinal($70));
      if (c_x_flip <> 0) then
      begin
        temp119 := 3;
      end
      else
      begin
        temp119 := 0;
      end;
      c_byte_index_xor := Cardinal(1 xor temp119);
      c_y_in_sprite_non_flipped := Cardinal(c_sprite_row_cache_entry^.c_y_in_sprite);
      if (c_y_flip <> 0) then
      begin
        temp120 := (Sub32(Sub32(c_height shl c_tile_height_shift, c_y_in_sprite_non_flipped), 1));
      end
      else
      begin
        temp120 := c_y_in_sprite_non_flipped;
      end;
      c_y_in_sprite := Cardinal(temp120);
      c_pixel_y_in_tile := Cardinal(Cardinal(c_y_in_sprite) and Cardinal(c_tile_height_mask));
      var PixelIndex := SpritePadding + Integer(c_x) - $80;
      if (c_x_flip <> 0) then
      begin
        c_nybble_shift[0] := Cardinal(0);
        c_nybble_shift[1] := Cardinal(4);
      end
      else
      begin
        c_nybble_shift[0] := Cardinal(4);
        c_nybble_shift[1] := Cardinal(0);
      end;
      c_j := Cardinal(0);
      while (Cardinal(c_j) < Cardinal(c_width)) do
      begin
        if (c_x_flip <> 0) then
        begin
          temp124 := (Sub32(Sub32(c_width, c_j), 1));
        end
        else
        begin
          temp124 := c_j;
        end;
        c_x_in_sprite := Cardinal(temp124);
        c_tile_index := Cardinal(Add32(Add32(c_sprite_tile_index, c_y_in_sprite shr c_tile_height_shift), Mul32(c_x_in_sprite, c_height)));
        c_tile_row_vram_address := Cardinal(Add32(c_base_tile_vram_address, (Add32(c_tile_index shl (3 + c_state^.c_double_resolution_enabled), c_pixel_y_in_tile)) shl 2));
        c_k := Cardinal(0);
        while (Cardinal(c_k) < Cardinal(8 div 2)) do
        begin
          c_byte := Cardinal(c_ReadVRAM(c_state, (Cardinal(Add32(c_tile_row_vram_address, c_k)) xor Cardinal(c_byte_index_xor))));
          c_l := Cardinal(0);
          while (Cardinal(c_l) < Cardinal(Length(c_nybble_shift))) do
          begin
            if (Integer(c_sprite_metapixels[PixelIndex] and $F) = Integer(0)) then
            begin
              c_palette_line_index := Cardinal(Cardinal(c_byte shr c_nybble_shift[c_l]) and Cardinal($F));
              c_sprite_metapixels[PixelIndex] := Byte(Cardinal(c_metapixel_high_bits) or Cardinal(c_palette_line_index));
            end;
            Inc(PixelIndex);
            Dec(c_pixel_limit);
            if (Cardinal(c_pixel_limit) = Cardinal(0)) then
            begin
              Exit;
            end;
            Inc(c_l);
          end;
          Inc(c_k);
        end;
        Inc(c_j);
      end;
    end;
    Dec(c_sprite_limit);
    if (Cardinal(c_sprite_limit) = Cardinal(0)) then
    begin
      Break;
    end;
    Inc(c_i);
  end;
  c_state^.c_allow_sprite_masking := Byte(0);
end;

procedure c_RenderScrollPlane(c_vdp_: PVDP; c_left_boundary: Cardinal; c_right_boundary: Cardinal; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_plane_index: Cardinal);
var
  c_state: PVDPState;
  c_hscroll_vram_address: Cardinal;
  c_hscroll: Cardinal;
  c_scroll_offset: Cardinal;
  c_plane_x_offset: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  if (not (c_vdp_^.c_configuration.c_planes_disabled[c_plane_index] <> 0)) then
  begin
    c_hscroll_vram_address := Cardinal(Add32(Add32(c_state^.c_hscroll_address, Mul32(c_plane_index, 2)), c_GetHScrollTableOffset(c_state, c_scanline)));
    c_hscroll := Cardinal(Add32(Cardinal(c_ReadVRAM(c_state, (Cardinal(c_hscroll_vram_address) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(c_hscroll_vram_address) xor Cardinal(1))) shl 8), (((c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2) * 2) * 8));
    c_scroll_offset := Cardinal(Sub32(8 * 2, Cardinal(c_hscroll) mod Cardinal(8 * 2)));
    c_plane_x_offset := Sub32(0, c_hscroll div (8 * 2));
    c_RenderScrollingPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_index, c_plane_x_offset, PlanePadding - Integer(c_scroll_offset), c_plane_metapixels, c_blit_lookup_list);
  end;
end;

procedure c_RenderForegroundPlane(c_vdp_: PVDP; c_left_boundary: Cardinal; c_right_boundary: Cardinal; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_window_plane: Byte);
begin
  var temp129: Integer := Ord(c_window_plane <> 0);
  if temp129 <> 0 then
  begin
    temp129 := Ord(not (c_vdp_^.c_configuration.c_window_disabled <> 0));
  end;
  if (temp129 <> 0) then
  begin
    c_RenderWindowPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_metapixels, c_blit_lookup_list);
  end
  else
  begin
    c_RenderScrollPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_metapixels, c_blit_lookup_list, 0);
  end;
end;

procedure c_RenderSpritePlane(var c_plane_metapixels: array of Byte; var c_sprite_metapixels: array of Byte; c_blit_lookup_list: PBlitLookup; c_mask: Cardinal; c_left_boundary_pixels: Cardinal; c_right_boundary_pixels: Cardinal);
begin
  for var PixelIndex := Integer(c_left_boundary_pixels) to Integer(c_right_boundary_pixels) - 1 do
  begin
    var PlaneIndex := PlanePadding + PixelIndex;
    var SpritePixel := c_sprite_metapixels[SpritePadding + PixelIndex];
    var PlanePixel := c_plane_metapixels[PlaneIndex];
    c_plane_metapixels[PlaneIndex] := c_blit_lookup_list^.c_lower[SpritePixel].c_pixels[PlanePixel] and c_mask;
  end;
end;

procedure c_RenderForegroundAndSpritePlanes(c_vdp_: PVDP; c_scanline: Cardinal; var c_plane_metapixels: array of Byte; var c_sprite_metapixels: array of Byte; c_window_plane: Byte; c_scanline_rendered_callback: TVDPScanlineRenderedCallback; c_scanline_rendered_callback_user_data: Pointer);
var
  c_state: PVDPState;
  temp132: Integer;
  temp133: Integer;
  temp134: Cardinal;
  temp135: Cardinal;
  temp136: Cardinal;
  temp137: Integer;
  temp138: Cardinal;
  temp139: Integer;
  temp144: Integer;
  temp145: Integer;
  temp146: Cardinal;
  temp147: Cardinal;
  temp148: Cardinal;
  temp149: Cardinal;
  temp150: Cardinal;
  temp151: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  var c_full_window_plane_line: Byte := Byte(Ord(Integer(Ord(Cardinal(c_scanline) < Cardinal(c_state^.c_window.c_vertical_boundary))) <> Integer(c_state^.c_window.c_aligned_bottom)));
  if (Integer(c_state^.c_window.c_horizontal_boundary) = Integer(0)) then
  begin
    temp132 := 0;
  end
  else
  begin
    temp132 := (((c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2) + c_state^.c_window.c_horizontal_boundary);
  end;
  var c_window_horizontal_boundary: Cardinal := temp132;
  if (c_full_window_plane_line <> 0) then
  begin
    temp133 := 0;
  end
  else
  begin
    if (Integer(c_state^.c_window.c_aligned_right) = Integer(c_window_plane)) then
    begin
      temp134 := c_window_horizontal_boundary;
    end
    else
    begin
      temp134 := 0;
    end;
    temp133 := temp134;
  end;
  var c_left_boundary: Cardinal := temp133;
  if (c_full_window_plane_line <> 0) then
  begin
    if (c_window_plane <> 0) then
    begin
      if (c_vdp_^.c_state.c_h40_enabled <> 0) then
      begin
        temp137 := 20;
      end
      else
      begin
        temp137 := 16;
      end;
      temp136 := (Add32(temp137, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)));
    end
    else
    begin
      temp136 := 0;
    end;
    temp135 := temp136;
  end
  else
  begin
    if (Integer(c_state^.c_window.c_aligned_right) = Integer(c_window_plane)) then
    begin
      if (c_vdp_^.c_state.c_h40_enabled <> 0) then
      begin
        temp139 := 20;
      end
      else
      begin
        temp139 := 16;
      end;
      temp138 := (Add32(temp139, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2)));
    end
    else
    begin
      temp138 := c_window_horizontal_boundary;
    end;
    temp135 := temp138;
  end;
  var c_right_boundary: Cardinal := temp135;
  var c_left_boundary_pixels: Cardinal := Cardinal(Mul32(c_left_boundary, 8 * 2));
  var c_right_boundary_pixels: Cardinal := Cardinal(Mul32(c_right_boundary, 8 * 2));
  if (Cardinal(c_left_boundary) = Cardinal(c_right_boundary)) then
  begin
    Exit;
  end;
  if (c_state^.c_display_enabled <> 0) then
  begin
    if (not (c_state^.c_debug.c_hide_layers <> 0)) then
    begin
      c_RenderForegroundPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_metapixels, @c_blit_lookup.c_normal, c_window_plane);
      if (c_state^.c_shadow_highlight_enabled <> 0) then
      begin
        c_RenderSpritePlane(c_plane_metapixels, c_sprite_metapixels, @c_blit_lookup.c_shadow_highlight, $FF, c_left_boundary_pixels, c_right_boundary_pixels);
      end
      else
      begin
        c_RenderSpritePlane(c_plane_metapixels, c_sprite_metapixels, @c_blit_lookup.c_normal, $3F, c_left_boundary_pixels, c_right_boundary_pixels);
      end;
    end;
    case c_state^.c_debug.c_forced_layer of
      1:
        begin
          c_RenderSpritePlane(c_plane_metapixels, c_sprite_metapixels, @c_blit_lookup.c_forced_layer, $FF, c_left_boundary_pixels, c_right_boundary_pixels);
        end;
      2:
        begin
          c_RenderScrollPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_metapixels, @c_blit_lookup.c_forced_layer, 0);
        end;
      3:
        begin
          c_RenderScrollPlane(c_vdp_, c_left_boundary, c_right_boundary, c_scanline, c_plane_metapixels, @c_blit_lookup.c_forced_layer, 1);
        end;
    end;
  end;
  var c_input_extra_tiles: Cardinal := Cardinal((((c_vdp_^.c_configuration.c_widescreen_tiles + (2 - 1)) div 2) * 2) * 2);
  var c_input_extra_tiles_in_pixels: Cardinal := Cardinal(Mul32(c_input_extra_tiles, 8));
  var c_output_extra_tiles: Cardinal := c_vdp_^.c_configuration.c_widescreen_tiles * 2;
  var c_output_extra_tiles_in_pixels: Cardinal := Cardinal(Mul32(c_output_extra_tiles, 8));
  var c_x_offset: Cardinal := Cardinal(Cardinal(Sub32(c_input_extra_tiles_in_pixels, c_output_extra_tiles_in_pixels)) div Cardinal(2));
  if (c_state^.c_h40_enabled <> 0) then
  begin
    temp144 := 20;
  end
  else
  begin
    temp144 := 16;
  end;
  var c_output_width: Cardinal := Cardinal(Add32((temp144 * 2) * 8, c_output_extra_tiles_in_pixels));
  if (c_state^.c_v30_enabled <> 0) then
  begin
    temp145 := 30;
  end
  else
  begin
    temp145 := 28;
  end;
  var c_output_height: Cardinal := Cardinal(temp145 shl (3 + c_state^.c_double_resolution_enabled));
  if (Cardinal(Add32(c_x_offset, c_output_width)) < Cardinal(c_left_boundary_pixels)) then
  begin
    temp147 := (Add32(c_x_offset, c_output_width));
  end
  else
  begin
    temp147 := c_left_boundary_pixels;
  end;
  if (Cardinal(c_x_offset) > Cardinal(temp147)) then
  begin
    temp146 := c_x_offset;
  end
  else
  begin
    if (Cardinal(Add32(c_x_offset, c_output_width)) < Cardinal(c_left_boundary_pixels)) then
    begin
      temp148 := (Add32(c_x_offset, c_output_width));
    end
    else
    begin
      temp148 := c_left_boundary_pixels;
    end;
    temp146 := temp148;
  end;
  var c_clamped_left_boundary_pixels: Cardinal := Cardinal(Sub32(temp146, c_x_offset));
  if (Cardinal(Add32(c_x_offset, c_output_width)) < Cardinal(c_right_boundary_pixels)) then
  begin
    temp150 := (Add32(c_x_offset, c_output_width));
  end
  else
  begin
    temp150 := c_right_boundary_pixels;
  end;
  if (Cardinal(c_x_offset) > Cardinal(temp150)) then
  begin
    temp149 := c_x_offset;
  end
  else
  begin
    if (Cardinal(Add32(c_x_offset, c_output_width)) < Cardinal(c_right_boundary_pixels)) then
    begin
      temp151 := (Add32(c_x_offset, c_output_width));
    end
    else
    begin
      temp151 := c_right_boundary_pixels;
    end;
    temp149 := temp151;
  end;
  var c_clamped_right_boundary_pixels: Cardinal := Cardinal(Sub32(temp149, c_x_offset));
  c_scanline_rendered_callback(Pointer(c_scanline_rendered_callback_user_data), c_scanline, c_plane_metapixels, PlanePadding + Integer(c_x_offset), c_clamped_left_boundary_pixels, c_clamped_right_boundary_pixels, c_output_width, c_output_height);
end;

procedure c_VDP_BeginScanline(c_vdp_: PVDP);
var
  c_state: PVDPState;
begin
  c_state := @c_vdp_^.c_state;
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(Length(c_state^.c_vsram_cache))) do
  begin
    c_state^.c_vsram_cache[c_i] := Word(c_state^.c_vsram[c_i]);
    Inc(c_i);
  end;
end;

procedure c_VDP_EndScanline(c_vdp_: PVDP; c_scanline: Cardinal; c_scanline_rendered_callback: TVDPScanlineRenderedCallback; c_scanline_rendered_callback_user_data: Pointer);
var
  c_state: PVDPState;
  c_plane_metapixels_buffer: array[0..543] of Byte;
  c_sprite_metapixels_buffer: array[0..573] of Byte;
  temp156: Integer;
  temp157: Integer;
  temp158: Byte;
  temp159: Integer;
  temp160: Integer;
  temp161: Integer;
  temp163: Integer;
begin
  c_state := @c_vdp_^.c_state;
  if (Integer(30) > Integer(28)) then
  begin
    temp156 := 30;
  end
  else
  begin
    temp156 := 28;
  end;
  if (Integer(8) > Integer(16)) then
  begin
    temp157 := 8;
  end
  else
  begin
    temp157 := 16;
  end;
  Assert(Cardinal(c_scanline) < Cardinal(temp156 * temp157));
  c_UpdateSpriteCache(c_vdp_);
  FillChar(c_sprite_metapixels_buffer, SizeOf(c_sprite_metapixels_buffer), 0);
  if (not (c_vdp_^.c_configuration.c_sprites_disabled <> 0)) then
  begin
    c_RenderSprites(c_vdp_, c_sprite_metapixels_buffer, c_scanline);
  end;
  if (Integer(c_state^.c_debug.c_forced_layer) = Integer(0)) then
  begin
    temp158 := c_state^.c_background_colour;
  end
  else
  begin
    temp158 := $3F;
  end;
  if (Integer(20) > Integer(16)) then
  begin
    temp159 := 20;
  end
  else
  begin
    temp159 := 16;
  end;
  if (Integer(20) > Integer(16)) then
  begin
    temp160 := 20;
  end
  else
  begin
    temp160 := 16;
  end;
  if (Integer(20) > Integer(16)) then
  begin
    temp161 := 20;
  end
  else
  begin
    temp161 := 16;
  end;
  FillChar(c_plane_metapixels_buffer[PlanePadding], (((((32 - temp159) div 2) + temp160) + ((32 - temp161) div 2)) * (8 * 2)), temp158);
  var temp162: Integer := Ord(c_state^.c_display_enabled <> 0);
  if temp162 <> 0 then
  begin
    temp162 := Ord(not (c_state^.c_debug.c_hide_layers <> 0));
  end;
  if (temp162 <> 0) then
  begin
    if (c_vdp_^.c_state.c_h40_enabled <> 0) then
    begin
      temp163 := 20;
    end
    else
    begin
      temp163 := 16;
    end;
    c_RenderScrollPlane(c_vdp_, 0, (Add32(temp163, Mul32(Cardinal(Add32(Cardinal(c_vdp_^.c_configuration.c_widescreen_tiles), 2 - 1)) div Cardinal(2), 2))), c_scanline, c_plane_metapixels_buffer, @c_blit_lookup.c_normal, 1);
  end;
  c_RenderForegroundAndSpritePlanes(c_vdp_, c_scanline, c_plane_metapixels_buffer, c_sprite_metapixels_buffer, 1, c_scanline_rendered_callback, c_scanline_rendered_callback_user_data);
  c_RenderForegroundAndSpritePlanes(c_vdp_, c_scanline, c_plane_metapixels_buffer, c_sprite_metapixels_buffer, 0, c_scanline_rendered_callback, c_scanline_rendered_callback_user_data);
end;

function c_VDP_ReadData(c_vdp_: PVDP): Cardinal;
var
  c_state: PVDPState;
begin
  c_state := @c_vdp_^.c_state;
  var c_value: Cardinal := 0;
  c_state^.c_access.c_write_pending := Byte(0);
  if (not (c_IsInReadMode(c_state) <> 0)) then
  begin
    ;
  end
  else
  begin
    c_value := Cardinal(c_ReadAndIncrement(c_state));
  end;
  Exit(Cardinal(c_value));
end;

function c_VDP_ReadControl(c_vdp_: PVDP): Cardinal;
var
  c_state: PVDPState;
begin
  c_state := @c_vdp_^.c_state;
  var c_fifo_empty: Byte := 1;
  c_state^.c_access.c_write_pending := Byte(0);
  Exit(Cardinal((($3400 or (c_fifo_empty shl 9)) or (c_state^.c_currently_in_vblank shl 7)) or (c_state^.c_currently_in_vblank shl 3)));
end;

procedure c_UpdateFakeFIFO(c_state: PVDPState; c_value: Cardinal);
begin
  var c_last: Cardinal := Cardinal(Length(c_state^.c_previous_data_writes) - 1);
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(c_last)) do
  begin
    c_state^.c_previous_data_writes[c_i] := Word(c_state^.c_previous_data_writes[(Add32(c_i, 1))]);
    Inc(c_i);
  end;
  c_state^.c_previous_data_writes[c_last] := Word(c_value);
end;

procedure c_VDP_WriteData(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer);
var
  c_state: PVDPState;
begin
  c_state := @c_vdp_^.c_state;
  c_state^.c_access.c_write_pending := Byte(0);
  c_UpdateFakeFIFO(c_state, c_value);
  if (c_IsInReadMode(c_state) <> 0) then
  begin
    ;
    c_IncrementAccessAddressRegister(c_state);
  end
  else
  begin
    c_WriteAndIncrement(c_vdp_, c_value, c_colour_updated_callback, c_colour_updated_callback_user_data);
    if (c_IsDMAPending(c_state) <> 0) then
    begin
      c_ClearDMAPending(c_state);
      while True do
      begin
        if (Integer(c_state^.c_access.c_selected_buffer) = Integer(c_VDP_ACCESS_VRAM)) then
        begin
          c_WriteVRAM(c_vdp_, c_state^.c_access.c_address_register, Cardinal(c_value shr 8));
          c_IncrementAccessAddressRegister(c_state);
        end
        else
        begin
          c_WriteAndIncrement(c_vdp_, c_state^.c_previous_data_writes[0], c_colour_updated_callback, c_colour_updated_callback_user_data);
        end;
        c_state^.c_dma.c_source_address_low := (c_state^.c_dma.c_source_address_low + 1) and $FFFF;
        c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low and $FFFF);
        c_state^.c_dma.c_length := (c_state^.c_dma.c_length + $FFFF) and $FFFF;
        c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length and $FFFF);
        if not (Integer(c_state^.c_dma.c_length) <> Integer(0)) then
          Break;
      end;
    end;
  end;
end;

procedure c_VDP_WriteControl(c_vdp_: PVDP; c_value: Cardinal; c_colour_updated_callback: TVDPColourUpdatedCallback; c_colour_updated_callback_user_data: Pointer; c_dma_transfer_begin_callback: TVDPDMATransferBeginCallback; c_read_callback: TVDPReadCallback; c_read_callback_user_data: Pointer; c_kdebug_callback: TVDPKDebugCallback; c_kdebug_callback_user_data: Pointer; c_target_cycle: Cardinal);
var
  c_state: PVDPState;
  c_code_bitmask: Cardinal;
  temp170: Integer;
  c_reg: Cardinal;
  c_data: Cardinal;
  temp178: Integer;
  temp206: Integer;
  temp212: Integer;
  temp218: Integer;
  temp219: Integer;
  temp220: Integer;
  temp221: Integer;
  temp222: Integer;
  temp223: Integer;
  temp224: Integer;
  temp225: Integer;
  c_character: Byte;
  temp226: Integer;
  temp227: Word;
  temp228: Integer;
  c_total_reads: Cardinal;
  temp230: Integer;
  temp231: Integer;
  c_value_scope168: Cardinal;
begin
  c_state := @c_vdp_^.c_state;
  var temp169: Integer := Ord(c_state^.c_access.c_write_pending <> 0);
  if temp169 = 0 then
  begin
    temp169 := Ord(Cardinal(Cardinal(c_value) and Cardinal($C000)) <> Cardinal($8000));
  end;
  if (temp169 <> 0) then
  begin
    if (c_state^.c_access.c_write_pending <> 0) then
    begin
      if (c_state^.c_dma.c_enabled <> 0) then
      begin
        temp170 := $3C;
      end
      else
      begin
        temp170 := $1C;
      end;
      c_code_bitmask := Cardinal(temp170);
      c_state^.c_access.c_write_pending := Byte(0);
      c_state^.c_access.c_address_register := Cardinal(Cardinal(Cardinal(c_state^.c_access.c_address_register) and Cardinal($3FFF)) or Cardinal((Cardinal(c_value) and Cardinal(7)) shl 14));
      c_state^.c_access.c_code_register := Word(Cardinal(Cardinal(c_state^.c_access.c_code_register) and Cardinal(not c_code_bitmask)) or Cardinal(Cardinal(c_value shr 2) and Cardinal(c_code_bitmask)));
    end
    else
    begin
      c_state^.c_access.c_write_pending := Byte(1);
      c_state^.c_access.c_address_register := Cardinal(Cardinal(Cardinal(c_value) and Cardinal($3FFF)) or Cardinal(Cardinal(c_state^.c_access.c_address_register) and Cardinal(3 shl 14)));
      c_state^.c_access.c_code_register := Word(Cardinal(Cardinal(c_value shr 14) and Cardinal(3)) or Cardinal(c_state^.c_access.c_code_register and $3C));
    end;
    case (ArithmeticShiftRight(Integer(c_state^.c_access.c_code_register), 1) and 7) of
      0:
        begin
          c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_VRAM;
        end;
      4, 1:
        begin
          c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_CRAM;
        end;
      2:
        begin
          c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_VSRAM;
        end;
      6:
        begin
          c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_VRAM_8BIT;
        end;
    else
      begin
        c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_INVALID;
      end;
    end;
  end
  else
  begin
    c_reg := Cardinal(Cardinal(c_value shr 8) and Cardinal($1F));
    c_data := Cardinal(Cardinal(c_value) and Cardinal($FF));
    c_state^.c_access.c_selected_buffer := c_VDP_ACCESS_INVALID;
    temp178 := Ord(Cardinal(c_reg) <= Cardinal(10));
    if temp178 = 0 then
    begin
      temp178 := Ord(c_state^.c_mega_drive_mode_enabled <> 0);
    end;
    if (temp178 <> 0) then
    begin
      case c_reg of
        0:
          begin
            if (Cardinal(Cardinal(c_data) and Cardinal(1 shl 5)) <> Cardinal(0)) then
            begin
              ;
            end;
            c_state^.c_h_int_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 4)) <> Cardinal(0)));
            if (Cardinal(Cardinal(c_data) and Cardinal(1 shl 1)) <> Cardinal(0)) then
            begin
              ;
            end;
          end;
        1:
          begin
            c_state^.c_extended_vram_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 7)) <> Cardinal(0)));
            c_state^.c_display_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 6)) <> Cardinal(0)));
            c_state^.c_v_int_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 5)) <> Cardinal(0)));
            c_state^.c_dma.c_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 4)) <> Cardinal(0)));
            c_state^.c_v30_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 3)) <> Cardinal(0)));
            c_state^.c_mega_drive_mode_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 2)) <> Cardinal(0)));
          end;
        2:
          begin
            c_state^.c_plane_a_address := Cardinal((Cardinal(c_data) and Cardinal($78)) shl 10);
          end;
        3:
          begin
            c_state^.c_window_address := Cardinal((Cardinal(c_data) and Cardinal($7E)) shl 10);
          end;
        4:
          begin
            c_state^.c_plane_b_address := Cardinal((Cardinal(c_data) and Cardinal($F)) shl 13);
          end;
        5:
          begin
            c_state^.c_sprite_table_address := Cardinal(Cardinal(c_data) shl 9);
          end;
        6:
          begin
            c_state^.c_sprite_tile_index_rebase := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 5)) <> Cardinal(0)));
          end;
        7:
          begin
            c_state^.c_background_colour := Byte(Cardinal(c_data) and Cardinal($3F));
          end;
        8, 9:
          begin
          end;
        10:
          begin
            c_state^.c_h_int_interval := Byte(Byte(c_data));
          end;
        11:
          begin
            if (Cardinal(Cardinal(c_data) and Cardinal(1 shl 3)) <> Cardinal(0)) then
            begin
              ;
            end;
            if ((Cardinal(c_data) and Cardinal(4)) <> 0) then
            begin
              temp206 := c_VDP_VSCROLL_MODE_2CELL;
            end
            else
            begin
              temp206 := c_VDP_VSCROLL_MODE_FULL;
            end;
            c_state^.c_vscroll_mode := temp206;
            c_SetHScrollMode(c_state, Integer(Cardinal(c_data) and Cardinal(3)));
          end;
        12:
          begin
            c_state^.c_h40_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal((1 shl 7) or (1 shl 0))) <> Cardinal(0)));
            c_state^.c_shadow_highlight_enabled := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 3)) <> Cardinal(0)));
            case (Cardinal(c_data shr 1) and Cardinal(3)) of
              0, 1:
                begin
                  c_state^.c_double_resolution_enabled := Byte(0);
                end;
              2:
                begin
                  c_state^.c_double_resolution_enabled := Byte(0);
                  ;
                end;
              3:
                begin
                  c_state^.c_double_resolution_enabled := Byte(1);
                end;
            end;
          end;
        13:
          begin
            c_state^.c_hscroll_address := Cardinal((Cardinal(c_data) and Cardinal($7F)) shl 10);
          end;
        14:
          begin
            c_state^.c_plane_a_tile_index_rebase := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 0)) <> Cardinal(0)));
            temp212 := Ord(Cardinal(Cardinal(c_data) and Cardinal(1 shl 4)) <> Cardinal(0));
            if temp212 <> 0 then
            begin
              temp212 := Ord(c_state^.c_plane_a_tile_index_rebase <> 0);
            end;
            c_state^.c_plane_b_tile_index_rebase := Byte(temp212);
          end;
        15:
          begin
            c_state^.c_access.c_increment := Byte(Byte(c_data));
          end;
        16:
          begin
            c_state^.c_plane_height_bitmask := Byte(Cardinal(c_data shl 1) or Cardinal($1F));
            case (Cardinal(c_data) and Cardinal(3)) of
              0:
                begin
                  c_state^.c_plane_width_shift := Byte(5);
                  c_state^.c_plane_height_bitmask := Byte(c_state^.c_plane_height_bitmask and $7F);
                end;
              1:
                begin
                  c_state^.c_plane_width_shift := Byte(6);
                  c_state^.c_plane_height_bitmask := Byte(c_state^.c_plane_height_bitmask and $3F);
                end;
              2:
                begin
                  c_state^.c_plane_width_shift := Byte(5);
                  c_state^.c_plane_height_bitmask := Byte(c_state^.c_plane_height_bitmask and 0);
                end;
              3:
                begin
                  c_state^.c_plane_width_shift := Byte(7);
                  c_state^.c_plane_height_bitmask := Byte(c_state^.c_plane_height_bitmask and $1F);
                end;
            end;
          end;
        17:
          begin
            c_state^.c_window.c_aligned_right := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal($80)) <> Cardinal(0)));
            if (Integer(20) > Integer(16)) then
            begin
              temp219 := 20;
            end
            else
            begin
              temp219 := 16;
            end;
            if (Integer(20) > Integer(16)) then
            begin
              temp220 := 20;
            end
            else
            begin
              temp220 := 16;
            end;
            if (Integer(20) > Integer(16)) then
            begin
              temp221 := 20;
            end
            else
            begin
              temp221 := 16;
            end;
            if (Cardinal((((32 - temp219) div 2) + temp220) + ((32 - temp221) div 2)) < Cardinal(Cardinal(c_data) and Cardinal($1F))) then
            begin
              if (Integer(20) > Integer(16)) then
              begin
                temp222 := 20;
              end
              else
              begin
                temp222 := 16;
              end;
              if (Integer(20) > Integer(16)) then
              begin
                temp223 := 20;
              end
              else
              begin
                temp223 := 16;
              end;
              if (Integer(20) > Integer(16)) then
              begin
                temp224 := 20;
              end
              else
              begin
                temp224 := 16;
              end;
              temp218 := ((((32 - temp222) div 2) + temp223) + ((32 - temp224) div 2));
            end
            else
            begin
              temp218 := (Cardinal(c_data) and Cardinal($1F));
            end;
            c_state^.c_window.c_horizontal_boundary := Word(temp218);
          end;
        18:
          begin
            c_state^.c_window.c_aligned_bottom := Byte(Ord(Cardinal(Cardinal(c_data) and Cardinal($80)) <> Cardinal(0)));
            c_state^.c_window.c_vertical_boundary := Word((Cardinal(c_data) and Cardinal($1F)) shl (3 + c_state^.c_double_resolution_enabled));
          end;
        19:
          begin
            c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length and (not ($FF shl 0)));
            c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length or (c_data shl 0));
          end;
        20:
          begin
            c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length and (not ($FF shl 8)));
            c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length or (c_data shl 8));
          end;
        21:
          begin
            c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low and (not ($FF shl 0)));
            c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low or (c_data shl 0));
          end;
        22:
          begin
            c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low and (not ($FF shl 8)));
            c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low or (c_data shl 8));
          end;
        23:
          begin
            if (Cardinal(Cardinal(c_data) and Cardinal($80)) <> Cardinal(0)) then
            begin
              c_state^.c_dma.c_source_address_high := Byte(Cardinal(c_data) and Cardinal($3F));
              if (Cardinal(Cardinal(c_data) and Cardinal($40)) <> Cardinal(0)) then
              begin
                temp225 := c_VDP_DMA_MODE_COPY;
              end
              else
              begin
                temp225 := c_VDP_DMA_MODE_FILL;
              end;
              c_state^.c_dma.c_mode := temp225;
            end
            else
            begin
              c_state^.c_dma.c_source_address_high := Byte(Cardinal(c_data) and Cardinal($7F));
              c_state^.c_dma.c_mode := c_VDP_DMA_MODE_MEMORY_TO_VRAM;
            end;
          end;
        30:
          begin
            repeat
              c_character := Byte((Integer(c_data) and ((Integer(1) shl 7) - 1)) - (Integer(c_data) and (Integer(1) shl 7)));
              temp226 := Ord(Integer(c_character) < Integer($20));
              if temp226 <> 0 then
              begin
                temp226 := Ord(Integer(c_character) <> Integer(0));
              end;
              if (temp226 <> 0) then
              begin
                Break;
              end;
              temp227 := c_state^.c_kdebug_buffer_index;
              Inc(c_state^.c_kdebug_buffer_index);
              c_state^.c_kdebug_buffer[temp227] := Byte(c_character);
              temp228 := Ord(Integer(c_character) = Integer(0));
              if temp228 = 0 then
              begin
                temp228 := Ord(Integer(c_state^.c_kdebug_buffer_index) = Integer(Length(c_state^.c_kdebug_buffer) - 1));
              end;
              if (temp228 <> 0) then
              begin
                c_state^.c_kdebug_buffer_index := Word(0);
                c_kdebug_callback(Pointer(c_kdebug_callback_user_data), @c_state^.c_kdebug_buffer[0]);
              end;
            until True;
          end;
      else
        begin
          ;
        end;
      end;
    end;
  end;
  var temp229: Integer := Ord(c_IsDMAPending(c_state) <> 0);
  if temp229 <> 0 then
  begin
    temp229 := Ord(Integer(c_state^.c_dma.c_mode) <> Integer(c_VDP_DMA_MODE_FILL));
  end;
  if (temp229 <> 0) then
  begin
    c_ClearDMAPending(c_state);
    if (Integer(c_state^.c_dma.c_mode) = Integer(c_VDP_DMA_MODE_MEMORY_TO_VRAM)) then
    begin
      if (Integer(c_state^.c_dma.c_length) = Integer(0)) then
      begin
        temp230 := $10000;
      end
      else
      begin
        temp230 := c_state^.c_dma.c_length;
      end;
      c_total_reads := Cardinal(temp230);
      temp231 := Ord(Integer(c_state^.c_access.c_selected_buffer) = Integer(c_VDP_ACCESS_VRAM));
      if temp231 <> 0 then
      begin
        temp231 := Ord(not (c_state^.c_extended_vram_enabled <> 0));
      end;
      c_dma_transfer_begin_callback(Pointer(c_read_callback_user_data), (c_total_reads shl temp231), c_target_cycle);
    end;
    while True do
    begin
      if (Integer(c_state^.c_dma.c_mode) = Integer(c_VDP_DMA_MODE_MEMORY_TO_VRAM)) then
      begin
        c_value_scope168 := Cardinal(c_read_callback(Pointer(c_read_callback_user_data), (Cardinal(Cardinal(c_state^.c_dma.c_source_address_high) shl 17) or Cardinal(Cardinal(c_state^.c_dma.c_source_address_low) shl 1)), c_target_cycle));
        c_UpdateFakeFIFO(c_state, c_value_scope168);
        c_WriteAndIncrement(c_vdp_, c_value_scope168, c_colour_updated_callback, c_colour_updated_callback_user_data);
      end
      else
      begin
        c_WriteVRAM(c_vdp_, c_state^.c_access.c_address_register, c_ReadVRAM(c_state, c_state^.c_dma.c_source_address_low));
        c_IncrementAccessAddressRegister(c_state);
      end;
      c_state^.c_dma.c_source_address_low := (c_state^.c_dma.c_source_address_low + 1) and $FFFF;
      c_state^.c_dma.c_source_address_low := Word(c_state^.c_dma.c_source_address_low and $FFFF);
      c_state^.c_dma.c_length := (c_state^.c_dma.c_length + $FFFF) and $FFFF;
      c_state^.c_dma.c_length := Word(c_state^.c_dma.c_length and $FFFF);
      if not (Integer(c_state^.c_dma.c_length) <> Integer(0)) then
        Break;
    end;
  end;
end;

procedure c_VDP_WriteDebugData(c_vdp_: PVDP; c_value: Cardinal);
begin
  case c_vdp_^.c_state.c_debug.c_selected_register of
    0:
      begin
        c_vdp_^.c_state.c_debug.c_hide_layers := Byte(Ord(Cardinal(Cardinal(c_value) and Cardinal(1 shl 6)) <> Cardinal(0)));
        c_vdp_^.c_state.c_debug.c_forced_layer := Byte(Cardinal(c_value shr 7) and Cardinal(3));
      end;
  end;
end;

procedure c_VDP_WriteDebugControl(c_vdp_: PVDP; c_value: Cardinal);
begin
  c_vdp_^.c_state.c_debug.c_selected_register := Byte(Cardinal(c_value shr 8) and Cardinal($F));
end;

function c_VDP_ReadVRAMWord(c_state: PVDPState; c_address: Cardinal): Cardinal;
begin
  Exit(Cardinal(Cardinal(c_ReadVRAM(c_state, (Cardinal(c_address) xor Cardinal(0)))) or Cardinal(c_ReadVRAM(c_state, (Cardinal(c_address) xor Cardinal(1))) shl 8)));
end;

function c_VDP_DecomposeTileMetadata(c_packed_tile_metadata: Cardinal): TVDPTileMetadata;
var
  c_tile_metadata: TVDPTileMetadata;
begin
  c_tile_metadata.c_tile_index := Cardinal(Cardinal(c_packed_tile_metadata) and Cardinal($7FF));
  c_tile_metadata.c_palette_line := Cardinal(Cardinal(c_packed_tile_metadata shr 13) and Cardinal(3));
  c_tile_metadata.c_x_flip := Byte(Ord(Cardinal(Cardinal(c_packed_tile_metadata) and Cardinal($800)) <> Cardinal(0)));
  c_tile_metadata.c_y_flip := Byte(Ord(Cardinal(Cardinal(c_packed_tile_metadata) and Cardinal($1000)) <> Cardinal(0)));
  c_tile_metadata.c_priority := Byte(Ord(Cardinal(Cardinal(c_packed_tile_metadata) and Cardinal($8000)) <> Cardinal(0)));
  Exit(c_tile_metadata);
end;

function c_VDP_GetCachedSprite(c_state: PVDPState; c_sprite_index: Cardinal): TVDPCachedSprite;
var
  c_cached_sprite: TVDPCachedSprite;
begin
  var SpriteBytes := c_state^.c_sprite_table_cache[c_sprite_index];
  c_cached_sprite.c_y := Cardinal((SpriteBytes[0] or ((SpriteBytes[1] and 3) shl 8)) and ArithmeticShiftRight(Integer($3FF), Ord(not (c_state^.c_double_resolution_enabled <> 0))));
  c_cached_sprite.c_link := Cardinal(SpriteBytes[2] and $7F);
  c_cached_sprite.c_width := Cardinal((ArithmeticShiftRight(Integer(SpriteBytes[3]), 2) and 3) + 1);
  c_cached_sprite.c_height := Cardinal((SpriteBytes[3] and 3) + 1);
  Exit(c_cached_sprite);
end;

end.


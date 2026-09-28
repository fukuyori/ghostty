const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fontconfig = @import("fontconfig");
const freetype = @import("freetype");
const macos = @import("macos");
const opentype = @import("opentype.zig");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Presentation = @import("main.zig").Presentation;
const Variation = @import("main.zig").face.Variation;
const global = @import("../global.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32").everything else struct {};

const log = std.log.scoped(.discovery);

/// Discover implementation for the compile options.
pub const Discover = switch (options.backend) {
    .freetype => void, // no discovery
    .freetype_windows => Windows,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, // no discovery
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero
/// value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: ?[:0]const u8 = null,

    /// Specific font style to search for. This will filter the style
    /// string the font advertises. The "bold/italic" booleans later in this
    /// struct filter by the style trait the font has, not the string, so
    /// these can be used in conjunction or not.
    style: ?[:0]const u8 = null,

    /// A codepoint that this font must be able to render.
    codepoint: u32 = 0,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: f32 = 0,

    /// True if we want to search specifically for a font that supports
    /// specific styles.
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// Variation axes to apply to the font. This also impacts searching
    /// for fonts since fonts with the ability to set these variations
    /// will be preferred, but not guaranteed.
    variations: []const Variation = &.{},

    /// Hash the descriptor with the given hasher.
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);

            // This is not correct, but we don't currently depend on the
            // hash value being different based on decimal values of variations.
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    /// Deep copy of the struct. The given allocator is expected to
    /// be an arena allocator of some sort since the descriptor
    /// itself doesn't support fine-grained deallocation of fields.
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        // We can't do any errdefer cleanup in here. As documented we
        // expect the allocator to be an arena so any errors should be
        // cleaned up somewhere else.

        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @intFromEnum(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @intFromEnum(fontconfig.Slant.italic) },
            false,
        ));

        // For fontconfig, we always add monospace in the pattern. Since
        // fontconfig sorts by closeness to the pattern, this doesn't fully
        // exclude non-monospace but helps prefer it.
        assert(pat.add(
            .spacing,
            .{ .integer = @intFromEnum(fontconfig.Spacing.mono) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }

        // Style
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }

        // Codepoint support
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }

        // Set our size attribute if set
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }

        // Build our traits. If we set any, then we store it in the attributes
        // otherwise we do nothing. We determine this by setting up the packed
        // struct, converting to an int, and checking if it is non-zero.
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();

            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );

            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }

        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init(lib: Library) Fontconfig {
        _ = lib;
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;

        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};

pub const CoreText = struct {
    pub fn init(lib: Library) CoreText {
        _ = lib;
        // Required for the "interface" but does nothing for CoreText.
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        _ = self;
    }

    /// Warm up the system font registry.
    ///
    /// The first CoreText query in a process initializes the system font
    /// database, which takes multiple milliseconds, while subsequent
    /// queries are microseconds.
    pub fn warmup() void {
        const name = macos.foundation.String.createWithBytes(
            "AppleColorEmoji",
            .utf8,
            false,
        ) catch return;
        defer name.release();
        const ct_font = macos.text.Font.createWithName(name, 12) catch return;
        ct_font.release();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();

        // Sort our descriptors
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);

        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// Discover a font by its exact name (family, full, or PostScript
    /// name). This is significantly faster than `discover` because it
    /// avoids the system-wide font matching that CTFontCollection does
    /// (which takes multiple milliseconds). This should be preferred
    /// when the desired font is known exactly, e.g. system fonts such
    /// as Apple Color Emoji.
    ///
    /// Returns null if no font with this exact family name exists;
    /// CoreText fallback fonts are never returned.
    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            family,
            .utf8,
            false,
        );
        defer family_str.release();

        // Create our font. We need a size to initialize it so we use size
        // 12 but we will alter the size later (same as DiscoverIterator).
        const ct_font = try macos.text.Font.createWithName(family_str, 12);

        // CTFontCreateWithName never returns null: if the requested font
        // isn't installed it returns a substitute font. Verify we got
        // the family we asked for, otherwise report not found.
        const found: bool = found: {
            const actual = ct_font.copyFamilyName();
            defer actual.release();
            var buf: [256]u8 = undefined;
            const actual_slice = actual.cstring(&buf, .utf8) orelse
                break :found false;
            break :found std.mem.eql(u8, actual_slice, family);
        };
        if (!found) {
            ct_font.release();
            return null;
        }

        return .{ .ct = .{
            .font = ct_font,
            .variations = &.{},
        } };
    }

    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If we have a codepoint within the CJK unified ideographs block
        // then we fallback to macOS to find a font that supports it because
        // there isn't a better way manually with CoreText that I can find that
        // properly takes into account system locale.
        //
        // References:
        // - http://unicode.org/charts/PDF/U4E00.pdf
        // - https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/platform/fonts/LocaleInFonts.md#unified-han-ideographs
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;

            // This is silly but our discover iterator needs a slice so
            // we allocate here. This isn't a performance bottleneck but
            // this is something we can optimize very easily...
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        const it = try self.discover(alloc, desc);

        // If our normal discovery doesn't find anything and we have a specific
        // codepoint, then fallback to using CTFontCreateForString to find a
        // matching font CoreText wants to use. See:
        // https://github.com/ghostty-org/ghostty/issues/2499
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;

            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        return it;
    }

    /// Discover a font for a specific codepoint using the CoreText
    /// CTFontCreateForString API.
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;

        if (comptime options.backend.hasFreetype()) {
            // If we have freetype, we can't use CoreText to find a font
            // that supports a specific codepoint because we need to
            // have a CoreText font to be able to do so.
            return null;
        }

        assert(desc.codepoint > 0);

        // Get our original font. This is dependent on the requested style
        // from the descriptor.
        const original = original: {
            // In all the styles below, we try to match it but if we don't
            // we always fall back to some other option. The order matters
            // here.

            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }

            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }

            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }

            break :original try collection.getFace(.{ .style = .regular });
        };

        // We need it in utf8 format
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );

        // We need a CFString
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();

        // Get our range length for CTFontCreateForString. It looks like
        // the range uses UTF-16 codepoints and not UTF-32 codepoints.
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };

        // Get our font
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();

        // Do not allow the last resort font to go through. This is the
        // last font used by CoreText if it can't find anything else and
        // only contains replacement characters.
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();

            // If the name doesn't fit in our buffer, then it can't
            // be the last resort font so we break out.
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;

            // If the name is "LastResort" then we don't want to use it.
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }

        // Get the descriptor
        return font.copyDescriptor();
    }

    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);

            // We need to retain because once the list is freed it will
            // release all its members.
            result[i].retain();
        }
        return result;
    }

    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        std.mem.sortUnstable(*macos.text.FontDescriptor, list, desc, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score: Score = .score(desc_inner, lhs);
                const rhs_score: Score = .score(desc_inner, rhs);
                // Higher score is "less" (earlier)
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }

    /// We represent our sorting score as a packed struct so that we
    /// can compare scores numerically but build scores symbolically.
    ///
    /// Note that packed structs store their fields from least to most
    /// significant, so the fields here are defined in increasing order
    /// of precedence.
    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

        /// Number of glyphs in the font, if two fonts have identical
        /// scores otherwise then we prefer the one with more glyphs.
        ///
        /// (Number of glyphs clamped at u16 intmax)
        glyph_count: u16 = 0,
        /// A fuzzy match on the style string, less important than
        /// an exact match, and less important than trait matches.
        fuzzy_style: u8 = 0,
        /// Whether the bold-ness of the font matches the descriptor.
        /// This is less important than italic because a font that's italic
        /// when it shouldn't be or not italic when it should be is a bigger
        /// problem (subjectively) than being the wrong weight.
        bold: bool = false,
        /// Whether the italic-ness of the font matches the descriptor.
        /// This is less important than an exact match on the style string
        /// because we want users to be allowed to override trait matching
        /// for the bold/italic/bold italic styles if they want.
        italic: bool = false,
        /// An exact (case-insensitive) match on the style string.
        exact_style: bool = false,
        /// Whether the font is monospace, this is more important than any of
        /// the other fields unless we're looking for a specific codepoint,
        /// in which case that is the most important thing.
        monospace: bool = false,
        /// If we're looking for a codepoint, whether this font has it.
        codepoint: bool = false,

        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }

        fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
            var self: Score = .{};

            // We always load the font if we can since some things can only be
            // inspected on the font itself. Fonts that can't be loaded score
            // 0 automatically because we don't want a font we can't load.
            const font: *macos.text.Font = macos.text.Font.createWithFontDescriptor(
                ct_desc,
                12,
            ) catch return self;
            defer font.release();

            // We prefer fonts with more glyphs, all else being equal.
            {
                const Type = @TypeOf(self.glyph_count);
                self.glyph_count = std.math.cast(
                    Type,
                    font.getGlyphCount(),
                ) orelse std.math.maxInt(Type);
            }

            // If we're searching for a codepoint, then we
            // prioritize fonts that have that codepoint.
            if (desc.codepoint > 0) {
                // Turn UTF-32 into UTF-16 for CT API
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    desc.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;

                // Get our glyphs
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                self.codepoint = font.getGlyphsForCharacters(
                    unichars[0..len],
                    glyphs[0..len],
                );
            }

            // Get our symbolic traits for the descriptor so we can
            // compare boolean attributes like bold, monospace, etc.
            const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
                const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
                defer traits.release();

                const key = macos.text.FontTraitKey.symbolic.key();
                const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                    break :traits .{};

                break :traits macos.text.FontSymbolicTraits.init(symbolic);
            };

            self.monospace = symbolic_traits.monospace;

            // We try to derived data from the font itself, which is generally
            // more reliable than only using the symbolic traits for this.
            const is_bold: bool, const is_italic: bool = derived: {
                // We start with initial guesses based on the symbolic traits,
                // but refine these with more information if we can get it.
                var is_italic = symbolic_traits.italic;
                var is_bold = symbolic_traits.bold;

                // Read the 'head' table out of the font data if it's available.
                if (head: {
                    const tag = macos.text.FontTableTag.init("head");
                    const data = font.copyTable(tag) orelse break :head null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :head opentype.Head.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing head table: {}", .{err});
                        break :head null;
                    };
                }) |head_| {
                    const head: opentype.Head = head_;
                    is_bold = is_bold or (head.macStyle & 1 == 1);
                    is_italic = is_italic or (head.macStyle & 2 == 2);
                }

                // Read the 'OS/2' table out of the font data if it's available.
                if (os2: {
                    const tag = macos.text.FontTableTag.init("OS/2");
                    const data = font.copyTable(tag) orelse break :os2 null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing OS/2 table: {}", .{err});
                        break :os2 null;
                    };
                }) |os2| {
                    is_bold = is_bold or os2.fsSelection.bold;
                    is_italic = is_italic or os2.fsSelection.italic;
                }

                // Check if we have variation axes in our descriptor, if we
                // do then we can derive weight italic-ness or both from them.
                if (font.copyAttribute(.variation_axes)) |axes| variations: {
                    defer axes.release();

                    // Copy the variation values for this instance of the font.
                    // if there are none then we just break out immediately.
                    const values: *macos.foundation.Dictionary =
                        font.copyAttribute(.variation) orelse break :variations;
                    defer values.release();

                    var buf: [1024]u8 = undefined;

                    // If we see the 'ital' value then we ignore 'slnt'.
                    var ital_seen = false;

                    const len = axes.getCount();
                    for (0..len) |i| {
                        const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                        const Key = macos.text.FontVariationAxisKey;
                        const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                        const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                        const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                        const name_str = cf_name.cstring(&buf, .utf8) orelse "";

                        // Default value
                        var def: f64 = 0;
                        _ = cf_def.getValue(.double, &def);
                        // Value in this font
                        var val: f64 = def;
                        if (values.getValue(
                            macos.foundation.Number,
                            cf_id,
                        )) |cf_val| _ = cf_val.getValue(.double, &val);

                        if (std.mem.eql(u8, "wght", name_str)) {
                            // Somewhat subjective threshold, we consider fonts
                            // bold if they have a 'wght' set greater than 600.
                            is_bold = val > 600;
                            continue;
                        }
                        if (std.mem.eql(u8, "ital", name_str)) {
                            is_italic = val > 0.5;
                            ital_seen = true;
                            continue;
                        }
                        if (!ital_seen and std.mem.eql(u8, "slnt", name_str)) {
                            // Arbitrary threshold of anything more than a 5
                            // degree clockwise slant is considered italic.
                            is_italic = val <= -5.0;
                            continue;
                        }
                    }
                }

                break :derived .{ is_bold, is_italic };
            };

            self.bold = desc.bold == is_bold;
            self.italic = desc.italic == is_italic;

            // Get the style string from the font.
            var style_str_buf: [128]u8 = undefined;
            const style_str: []const u8 = style_str: {
                const style = ct_desc.copyAttribute(.style_name) orelse
                    break :style_str "";
                defer style.release();

                break :style_str style.cstring(&style_str_buf, .utf8) orelse "";
            };

            // The first string in this slice will be used for the exact match,
            // and for the fuzzy match, all matching substrings will increase
            // the rank.
            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};

                // If we don't have an explicitly desired style name, we base
                // it on the bold and italic properties, this isn't ideal since
                // fonts may use style names other than these, but it helps in
                // some edge cases.
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };

            self.exact_style = std.ascii.eqlIgnoreCase(
                style_str,
                desired_styles[0],
            );
            // Our "fuzzy match" score is 0 if the desired style isn't present
            // in the string, otherwise we give higher priority for styles that
            // have fewer characters not in the desired_styles list.
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            self.fuzzy_style = @intCast(style_str.len);
            for (desired_styles) |s| {
                if (std.ascii.indexOfIgnoreCase(style_str, s) != null) {
                    self.fuzzy_style -|= @intCast(s.len);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| self.fuzzy_style;

            return self;
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            for (self.list) |desc| {
                desc.release();
            }
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;

            // Get our descriptor. We need to remove the character set
            // limitation because we may have used that to filter but we
            // don't want it anymore because it'll restrict the characters
            // available.
            const desc = desc: {
                // We create a copy, overwriting the character set attribute.
                const attrs = try macos.foundation.MutableDictionary.create(0);
                defer attrs.release();

                attrs.setValue(
                    macos.text.FontAttribute.character_set.key(),
                    macos.c.kCFNull,
                );

                break :desc try macos.text.FontDescriptor.createCopyWithAttributes(
                    self.list[self.i],
                    @ptrCast(attrs),
                );
            };
            defer desc.release();

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .ct = .{
                    .font = font,
                    .variations = self.variations,
                },
            };
        }
    };
};

/// Windows font discovery. Enumerates font files in the system and
/// per-user font directories and matches them to a descriptor via
/// FreeType's family_name field (with a fallback to the SFNT name
/// table when family_name is missing).
///
/// No external service is used; each discover() call walks the
/// directories, opening candidate files with FreeType only as needed.
/// For typical Windows installations (~300 fonts) a name query is in
/// the tens of milliseconds. A codepoint fallback query may be
/// noticeably slower because every candidate has to be opened to
/// probe its CMap.
pub const Windows = struct {
    lib: Library,
    dwrite: ?DirectWrite,

    pub fn init(lib: Library) Windows {
        return .{
            .lib = lib,
            .dwrite = DirectWrite.init() catch |err| unavailable: {
                log.warn("DirectWrite font fallback unavailable err={}", .{err});
                break :unavailable null;
            },
        };
    }

    pub fn deinit(self: *Windows) void {
        if (self.dwrite) |*dwrite| dwrite.deinit();
        self.* = undefined;
    }

    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        return .{
            .alloc = alloc,
            .lib = self.lib,
            .desc = desc,
            .variations = desc.variations,
            .state = .system,
            .dir = null,
            .iter = null,
            .system_path = null,
            .user_path = null,
            .candidates = null,
            .candidate_index = 0,
            .rank_styles = true,
        };
    }

    pub fn discoverFallback(
        self: *Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !FallbackIterator {
        if (desc.codepoint == 0) return .{};
        const dwrite = if (self.dwrite) |*value| value else return .{};

        var family_buf: [512]u8 = undefined;
        const primary = primaryFamily(collection, &family_buf);

        return .{ .face = dwrite.map(
            alloc,
            self.lib,
            primary,
            desc,
        ) catch |err| failed: {
            log.warn("DirectWrite fallback failed codepoint=0x{X} err={}", .{
                desc.codepoint,
                err,
            });
            break :failed null;
        } };
    }

    pub const FallbackIterator = struct {
        face: ?DeferredFace = null,

        pub fn deinit(self: *FallbackIterator) void {
            if (self.face) |*face| face.deinit();
            self.* = undefined;
        }

        pub fn next(self: *FallbackIterator) !?DeferredFace {
            const face = self.face orelse return null;
            self.face = null;
            return face;
        }
    };

    fn primaryFamily(collection: *Collection, buf: []u8) ?[]const u8 {
        const face = collection.getFace(.{}) catch return null;
        return face.name(buf) catch null;
    }

    const LoadedFileFace = struct {
        face: Face,
        data: ?[]const u8 = null,
    };

    fn loadFileFace(
        alloc: Allocator,
        lib: Library,
        path: [:0]const u8,
        face_index: i32,
    ) !LoadedFileFace {
        const opts: @import("face.zig").Options = .{ .size = .{ .points = 12 } };
        var data: ?[]const u8 = null;
        const face = Face.initFile(lib, path, face_index, opts) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => memory: {
                const io = global.io();
                const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
                defer file.close(io);
                const size = std.math.cast(usize, (try file.stat(io)).size) orelse
                    return error.FileTooBig;
                var reader = file.reader(io, &.{});
                const bytes = try reader.interface.readAlloc(alloc, size);
                errdefer alloc.free(bytes);
                const memory_face = try Face.initMemory(lib, bytes, face_index, opts);
                data = bytes;
                break :memory memory_face;
            },
        };
        return .{ .face = face, .data = data };
    }

    const DirectWrite = struct {
        factory: *win32.IDWriteFactory,
        factory2: *win32.IDWriteFactory2,
        fonts: *win32.IDWriteFontCollection,
        fallback: *win32.IDWriteFontFallback,
        locale: [locale_name_max_length]u16,
        mutex: std.Io.Mutex = .init,

        const locale_name_max_length = 85;

        fn init() !DirectWrite {
            var unknown: *win32.IUnknown = undefined;
            try checkHr(win32.DWriteCreateFactory(
                win32.DWRITE_FACTORY_TYPE_SHARED,
                win32.IID_IDWriteFactory,
                &unknown,
            ));
            const factory: *win32.IDWriteFactory = @ptrCast(unknown);
            errdefer _ = factory.IUnknown.Release();

            var factory2_raw: *anyopaque = undefined;
            try checkHr(factory.IUnknown.QueryInterface(
                win32.IID_IDWriteFactory2,
                &factory2_raw,
            ));
            const factory2: *win32.IDWriteFactory2 = @ptrCast(@alignCast(factory2_raw));
            errdefer _ = factory2.IUnknown.Release();

            var fonts: *win32.IDWriteFontCollection = undefined;
            try checkHr(factory.GetSystemFontCollection(&fonts, win32.FALSE));
            errdefer _ = fonts.IUnknown.Release();

            var fallback: *win32.IDWriteFontFallback = undefined;
            try checkHr(factory2.GetSystemFontFallback(&fallback));
            errdefer _ = fallback.IUnknown.Release();

            var locale: [locale_name_max_length]u16 = @splat(0);
            if (win32.GetUserDefaultLocaleName(@ptrCast(&locale), locale.len) == 0) {
                const default = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
                @memcpy(locale[0..default.len], default);
            }

            return .{
                .factory = factory,
                .factory2 = factory2,
                .fonts = fonts,
                .fallback = fallback,
                .locale = locale,
            };
        }

        fn deinit(self: *DirectWrite) void {
            _ = self.fallback.IUnknown.Release();
            _ = self.fonts.IUnknown.Release();
            _ = self.factory2.IUnknown.Release();
            _ = self.factory.IUnknown.Release();
            self.* = undefined;
        }

        fn map(
            self: *DirectWrite,
            alloc: Allocator,
            lib: Library,
            primary_family: ?[]const u8,
            desc: Descriptor,
        ) !?DeferredFace {
            self.mutex.lockUncancelable(global.io());
            defer self.mutex.unlock(global.io());

            const primary_w: ?[:0]u16 = if (primary_family) |family|
                std.unicode.utf8ToUtf16LeAllocZ(alloc, family) catch |err| invalid: {
                    switch (err) {
                        error.OutOfMemory => return err,
                        error.InvalidUtf8 => {
                            log.warn("DirectWrite fallback ignored invalid UTF-8 primary family", .{});
                            break :invalid null;
                        },
                    }
                }
            else
                null;
            defer if (primary_w) |family| alloc.free(family);

            var text_buf: [2]u16 = undefined;
            const text = try encodeScalarUtf16(desc.codepoint, &text_buf);
            var source: TextSource = .{
                .interface = .{ .vtable = &TextSource.vtable },
                .text = text.ptr,
                .text_len = @intCast(text.len),
                .locale = @ptrCast(&self.locale),
            };

            var mapped_length: u32 = 0;
            var mapped_font: ?*win32.IDWriteFont = null;
            var scale: f32 = 1;
            try checkHr(self.fallback.MapCharacters(
                &source.interface,
                0,
                @intCast(text.len),
                self.fonts,
                if (primary_w) |family| family.ptr else null,
                win32.DWRITE_FONT_WEIGHT_REGULAR,
                win32.DWRITE_FONT_STYLE_NORMAL,
                win32.DWRITE_FONT_STRETCH_NORMAL,
                &mapped_length,
                @ptrCast(&mapped_font),
                &scale,
            ));

            const font = mapped_font orelse return null;
            defer _ = font.IUnknown.Release();
            if (mapped_length != text.len) {
                log.warn("DirectWrite fallback mapped partial scalar codepoint=0x{X} mapped={d} length={d}", .{
                    desc.codepoint,
                    mapped_length,
                    text.len,
                });
                return null;
            }
            if (scale != 1) {
                log.info("DirectWrite fallback ignored scale codepoint=0x{X} scale={d}", .{
                    desc.codepoint,
                    scale,
                });
            }

            const font_simulations = font.GetSimulations();
            if (@as(u32, @bitCast(font_simulations)) != 0) {
                log.info("DirectWrite fallback ignored font simulation codepoint=0x{X} simulation={}", .{
                    desc.codepoint,
                    font_simulations,
                });
            }

            var dwrite_face: *win32.IDWriteFontFace = undefined;
            try checkHr(font.CreateFontFace(&dwrite_face));
            defer _ = dwrite_face.IUnknown.Release();

            var file_count: u32 = 0;
            try checkHr(dwrite_face.GetFiles(&file_count, null));
            if (file_count != 1) {
                log.warn("DirectWrite fallback rejected codepoint=0x{X} file_count={d}", .{
                    desc.codepoint,
                    file_count,
                });
                return null;
            }

            var file_slot: [1]?*win32.IDWriteFontFile = .{null};
            try checkHr(dwrite_face.GetFiles(&file_count, &file_slot));
            const file = file_slot[0] orelse return error.MissingFontFile;
            defer _ = file.IUnknown.Release();

            var loader: *win32.IDWriteFontFileLoader = undefined;
            try checkHr(file.GetLoader(&loader));
            defer _ = loader.IUnknown.Release();

            var local_raw: *anyopaque = undefined;
            if (loader.IUnknown.QueryInterface(
                win32.IID_IDWriteLocalFontFileLoader,
                &local_raw,
            ) < 0) {
                log.warn("DirectWrite fallback rejected non-local font codepoint=0x{X}", .{desc.codepoint});
                return null;
            }
            const local: *win32.IDWriteLocalFontFileLoader = @ptrCast(@alignCast(local_raw));
            defer _ = local.IUnknown.Release();

            var reference_key: ?*anyopaque = null;
            var reference_key_size: u32 = 0;
            try checkHr(file.GetReferenceKey(@ptrCast(&reference_key), &reference_key_size));

            var path_len: u32 = 0;
            try checkHr(local.GetFilePathLengthFromKey(
                reference_key,
                reference_key_size,
                &path_len,
            ));
            const path_w = try alloc.allocSentinel(u16, path_len, 0);
            defer alloc.free(path_w);
            try checkHr(local.GetFilePathFromKey(
                reference_key,
                reference_key_size,
                path_w.ptr,
                path_len + 1,
            ));

            const path_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, path_w);
            defer alloc.free(path_utf8);
            const path = try alloc.dupeZ(u8, path_utf8);
            errdefer alloc.free(path);

            const face_index_u32 = dwrite_face.GetIndex();
            const face_index = std.math.cast(i32, face_index_u32) orelse
                return error.InvalidFaceIndex;
            var loaded = try loadFileFace(alloc, lib, path, face_index);
            errdefer {
                loaded.face.deinit();
                if (loaded.data) |data| alloc.free(data);
            }

            if (loaded.face.glyphIndex(desc.codepoint) == null) {
                log.warn("DirectWrite and FreeType disagree on fallback codepoint=0x{X} path={s} index={d}", .{
                    desc.codepoint,
                    path,
                    face_index,
                });
                loaded.face.deinit();
                if (loaded.data) |data| alloc.free(data);
                alloc.free(path);
                return null;
            }

            const presentation: Presentation = if (loaded.face.hasColor()) .emoji else .text;
            return .{
                .win = .{
                    .path = path,
                    .face_index = face_index,
                    .data = loaded.data,
                    // MapCharacters selected a system fallback face independently
                    // of the primary font. Primary-font variation settings are not
                    // valid for that unrelated face.
                    .variations = &.{},
                    .peek = loaded.face,
                    .presentation = presentation,
                    .alloc = alloc,
                },
            };
        }
    };

    const TextSource = extern struct {
        interface: win32.IDWriteTextAnalysisSource,
        text: [*]const u16,
        text_len: u32,
        locale: [*:0]const u16,

        const vtable: win32.IDWriteTextAnalysisSource.VTable = .{
            .base = .{
                .QueryInterface = queryInterface,
                .AddRef = addRef,
                .Release = release,
            },
            .GetTextAtPosition = getTextAtPosition,
            .GetTextBeforePosition = getTextBeforePosition,
            .GetParagraphReadingDirection = getParagraphReadingDirection,
            .GetLocaleName = getLocaleName,
            .GetNumberSubstitution = getNumberSubstitution,
        };

        fn fromInterface(value: anytype) *TextSource {
            const interface: *const win32.IDWriteTextAnalysisSource = @ptrCast(value);
            return @constCast(@fieldParentPtr("interface", interface));
        }

        fn queryInterface(
            value: *const win32.IUnknown,
            iid: *const win32.Guid,
            output: **anyopaque,
        ) callconv(.winapi) win32.HRESULT {
            const result: *?*anyopaque = @ptrCast(output);
            result.* = if (guidEqual(iid, win32.IID_IUnknown) or
                guidEqual(iid, win32.IID_IDWriteTextAnalysisSource))
                @ptrCast(&fromInterface(value).interface)
            else
                null;
            return if (result.* != null) win32.S_OK else win32.E_NOINTERFACE;
        }

        fn addRef(_: *const win32.IUnknown) callconv(.winapi) u32 {
            return 1;
        }

        fn release(_: *const win32.IUnknown) callconv(.winapi) u32 {
            return 1;
        }

        fn getTextAtPosition(
            value: *const win32.IDWriteTextAnalysisSource,
            position: u32,
            output: ?*const ?*u16,
            length: ?*u32,
        ) callconv(.winapi) win32.HRESULT {
            const self = fromInterface(value);
            const output_mut: ?*?*u16 = @constCast(output);
            if (position >= self.text_len) {
                if (output_mut) |ptr| ptr.* = null;
                if (length) |ptr| ptr.* = 0;
            } else {
                if (output_mut) |ptr| ptr.* = @constCast(&self.text[position]);
                if (length) |ptr| ptr.* = self.text_len - position;
            }
            return win32.S_OK;
        }

        fn getTextBeforePosition(
            value: *const win32.IDWriteTextAnalysisSource,
            position: u32,
            output: ?*const ?*u16,
            length: ?*u32,
        ) callconv(.winapi) win32.HRESULT {
            const self = fromInterface(value);
            const output_mut: ?*?*u16 = @constCast(output);
            if (position == 0 or position > self.text_len) {
                if (output_mut) |ptr| ptr.* = null;
                if (length) |ptr| ptr.* = 0;
            } else {
                if (output_mut) |ptr| ptr.* = @constCast(&self.text[0]);
                if (length) |ptr| ptr.* = position;
            }
            return win32.S_OK;
        }

        fn getParagraphReadingDirection(
            _: *const win32.IDWriteTextAnalysisSource,
        ) callconv(.winapi) win32.DWRITE_READING_DIRECTION {
            return win32.DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
        }

        fn getLocaleName(
            value: *const win32.IDWriteTextAnalysisSource,
            position: u32,
            length: ?*u32,
            locale: ?*const ?*u16,
        ) callconv(.winapi) win32.HRESULT {
            const self = fromInterface(value);
            if (length) |ptr| ptr.* = self.text_len -| position;
            const locale_mut: ?*?*u16 = @constCast(locale);
            if (locale_mut) |ptr| ptr.* = @constCast(&self.locale[0]);
            return win32.S_OK;
        }

        fn getNumberSubstitution(
            value: *const win32.IDWriteTextAnalysisSource,
            position: u32,
            length: ?*u32,
            substitution: **win32.IDWriteNumberSubstitution,
        ) callconv(.winapi) win32.HRESULT {
            const self = fromInterface(value);
            if (length) |ptr| ptr.* = self.text_len -| position;
            const result: *?*win32.IDWriteNumberSubstitution = @ptrCast(substitution);
            result.* = null;
            return win32.S_OK;
        }
    };

    fn checkHr(result: win32.HRESULT) !void {
        if (result < 0) return error.DirectWriteFailure;
    }

    fn guidEqual(a: *const win32.Guid, b: *const win32.Guid) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }

    fn encodeScalarUtf16(cp: u32, buf: *[2]u16) ![]const u16 {
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF))
            return error.InvalidCodepoint;
        if (cp <= 0xFFFF) {
            buf[0] = @intCast(cp);
            return buf[0..1];
        }

        const value = cp - 0x10000;
        buf[0] = @intCast(0xD800 + (value >> 10));
        buf[1] = @intCast(0xDC00 + (value & 0x3FF));
        return buf[0..2];
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        lib: Library,
        desc: Descriptor,
        variations: []const Variation,
        state: State,
        dir: ?std.Io.Dir,
        iter: ?std.Io.Dir.Iterator,
        system_path: ?[:0]const u8,
        user_path: ?[:0]const u8,
        candidates: ?std.ArrayListUnmanaged(Candidate),
        candidate_index: usize,
        rank_styles: bool,

        const State = enum { system, user, done };

        const Candidate = struct {
            face: ?DeferredFace,
            style_match: bool,
            exact_style: bool,
            fuzzy_style: u16,
            glyph_count: u32,

            fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
                if (lhs.style_match != rhs.style_match) return lhs.style_match;
                if (lhs.exact_style != rhs.exact_style) return lhs.exact_style;
                if (lhs.fuzzy_style != rhs.fuzzy_style)
                    return lhs.fuzzy_style > rhs.fuzzy_style;
                return lhs.glyph_count > rhs.glyph_count;
            }
        };

        pub fn deinit(self: *DiscoverIterator) void {
            if (self.dir) |*d| d.close(global.io());
            if (self.system_path) |p| self.alloc.free(p);
            if (self.user_path) |p| self.alloc.free(p);
            if (self.candidates) |*candidates| {
                for (candidates.items) |*candidate| {
                    if (candidate.face) |*face| face.deinit();
                }
                candidates.deinit(self.alloc);
            }
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (!self.rank_styles) return self.nextUnranked();

            if (self.candidates == null) {
                var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
                errdefer {
                    for (candidates.items) |*candidate| {
                        if (candidate.face) |*face| face.deinit();
                    }
                    candidates.deinit(self.alloc);
                }

                try self.collectCandidates(&candidates);
                const has_style_match = for (candidates.items) |candidate| {
                    if (candidate.style_match) break true;
                } else false;
                if (!has_style_match) {
                    for (candidates.items) |*candidate| {
                        if (candidate.face) |*face| face.deinit();
                    }
                    candidates.clearRetainingCapacity();
                }
                std.mem.sortUnstable(Candidate, candidates.items, {}, Candidate.lessThan);
                self.candidates = candidates;
            }

            const candidates = &self.candidates.?;
            if (self.candidate_index >= candidates.items.len) return null;
            const candidate = &candidates.items[self.candidate_index];
            self.candidate_index += 1;
            const face = candidate.face.?;
            candidate.face = null;
            return face;
        }

        fn nextUnranked(self: *DiscoverIterator) !?DeferredFace {
            while (true) {
                if (self.iter == null) {
                    switch (self.state) {
                        .system => {
                            const path = self.systemFontsPath() orelse {
                                self.state = .user;
                                continue;
                            };
                            self.system_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .user;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .user => {
                            const path = self.userFontsPath() orelse {
                                self.state = .done;
                                continue;
                            };
                            self.user_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .done;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .done => return null,
                    }
                }

                const entry = (self.iter.?.next(global.io()) catch null) orelse {
                    if (self.dir) |*d| d.close(global.io());
                    self.dir = null;
                    self.iter = null;
                    self.state = switch (self.state) {
                        .system => .user,
                        .user => .done,
                        .done => .done,
                    };
                    continue;
                };

                if (entry.kind != .file) continue;
                if (!isFontFile(entry.name)) continue;
                if (try self.firstMatch(entry.name)) |face| return face;
            }
        }

        fn firstMatch(self: *DiscoverIterator, name: []const u8) !?DeferredFace {
            const dir_path = switch (self.state) {
                .system => self.system_path.?,
                .user => self.user_path.?,
                .done => return null,
            };
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(
                &path_buf,
                "{s}\\{s}",
                .{ dir_path, name },
            ) catch return null;
            const is_ttc = std.ascii.endsWithIgnoreCase(name, ".ttc");
            const max_faces: i32 = if (is_ttc) 16 else 1;
            var face_index: i32 = 0;
            while (face_index < max_faces) : (face_index += 1) {
                var face = Face.initFile(
                    self.lib,
                    full_path,
                    face_index,
                    .{ .size = .{ .points = 12 } },
                ) catch break;
                if (self.matches(&face)) {
                    return try self.makeDeferred(face, full_path, face_index);
                }
                face.deinit();
            }
            return null;
        }

        fn collectCandidates(
            self: *DiscoverIterator,
            candidates: *std.ArrayListUnmanaged(Candidate),
        ) !void {
            while (true) {
                // Ensure we have a directory iterator for the current state.
                if (self.iter == null) {
                    switch (self.state) {
                        .system => {
                            const path = self.systemFontsPath() orelse {
                                self.state = .user;
                                continue;
                            };
                            self.system_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .user;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .user => {
                            const path = self.userFontsPath() orelse {
                                self.state = .done;
                                continue;
                            };
                            self.user_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .done;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .done => return,
                    }
                }

                const entry = (self.iter.?.next(global.io()) catch null) orelse {
                    // Finished this directory; advance state.
                    if (self.dir) |*d| d.close(global.io());
                    self.dir = null;
                    self.iter = null;
                    self.state = switch (self.state) {
                        .system => .user,
                        .user => .done,
                        .done => .done,
                    };
                    continue;
                };

                if (entry.kind != .file) continue;
                if (!isFontFile(entry.name)) continue;

                try self.addMatches(entry.name, candidates);
            }
        }

        /// Build the system fonts directory from %SYSTEMROOT%. Returns null
        /// if SYSTEMROOT is unset, which shouldn't happen on a healthy
        /// Windows install but we just skip the directory rather than
        /// falling back to a hardcoded drive letter.
        fn systemFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const systemroot = global.environ().getAlloc(
                self.alloc,
                "SYSTEMROOT",
            ) catch return null;
            defer self.alloc.free(systemroot);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Fonts",
                .{systemroot},
                0,
            ) catch null;
        }

        fn userFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const local_appdata = global.environ().getAlloc(
                self.alloc,
                "LOCALAPPDATA",
            ) catch return null;
            defer self.alloc.free(local_appdata);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Microsoft\\Windows\\Fonts",
                .{local_appdata},
                0,
            ) catch null;
        }

        fn addMatches(
            self: *DiscoverIterator,
            name: []const u8,
            candidates: *std.ArrayListUnmanaged(Candidate),
        ) !void {
            const dir_path = switch (self.state) {
                .system => self.system_path.?,
                .user => self.user_path.?,
                .done => return,
            };

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(
                &path_buf,
                "{s}\\{s}",
                .{ dir_path, name },
            ) catch return;

            const is_ttc = std.ascii.endsWithIgnoreCase(name, ".ttc");
            const max_faces: i32 = if (is_ttc) 16 else 1;

            // Probe each face in the file.
            var face_index: i32 = 0;
            while (face_index < max_faces) : (face_index += 1) {
                var face = Face.initFile(
                    self.lib,
                    full_path,
                    face_index,
                    .{ .size = .{ .points = 12 } },
                ) catch break;

                if (self.matches(&face)) {
                    const style_name = faceStyleName(&face);
                    const desired = desiredStyles(self.desc);
                    var fuzzy_style: u16 = 0;
                    for (desired) |style| {
                        if (std.ascii.indexOfIgnoreCase(style_name, style) != null) {
                            fuzzy_style +|= @intCast(style.len);
                        }
                    }

                    const style_match = styleMatches(&face, self.desc);
                    const exact_style = desired.len > 0 and
                        std.ascii.eqlIgnoreCase(style_name, desired[0]);
                    const glyph_count: u32 = @intCast(@max(
                        0,
                        face.face.handle.*.num_glyphs,
                    ));
                    var deferred = try self.makeDeferred(face, full_path, face_index);
                    errdefer deferred.deinit();
                    try candidates.append(self.alloc, .{
                        .face = deferred,
                        .style_match = style_match,
                        .exact_style = exact_style,
                        .fuzzy_style = fuzzy_style,
                        .glyph_count = glyph_count,
                    });
                    continue;
                }

                face.deinit();
            }

            return;
        }

        /// Check whether the given face matches the descriptor.
        fn matches(self: *const DiscoverIterator, face: *Face) bool {
            if (self.desc.family) |family| {
                if (!familyMatches(face, family)) return false;
            }
            if (self.desc.codepoint != 0) {
                if (face.glyphIndex(self.desc.codepoint) == null) return false;
            }
            return true;
        }

        fn makeDeferred(
            self: *DiscoverIterator,
            face: Face,
            full_path: []const u8,
            face_index: i32,
        ) !DeferredFace {
            const path_owned = try self.alloc.dupeZ(u8, full_path);
            errdefer self.alloc.free(path_owned);

            const presentation: Presentation =
                if (face.hasColor()) .emoji else .text;

            return DeferredFace{
                .win = .{
                    .path = path_owned,
                    .face_index = face_index,
                    .variations = self.variations,
                    .peek = face,
                    .presentation = presentation,
                    .alloc = self.alloc,
                },
            };
        }
    };

    fn isFontFile(name: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(name, ".ttf") or
            std.ascii.endsWithIgnoreCase(name, ".ttc") or
            std.ascii.endsWithIgnoreCase(name, ".otf");
    }

    /// Compare a face's family against a requested family name. Checks
    /// FreeType's family_name first, then falls back to the SFNT name
    /// table entry.
    fn familyMatches(face: *Face, family: [:0]const u8) bool {
        const ft_family: ?[*:0]const u8 = face.face.handle.*.family_name;
        if (ft_family) |f| {
            if (std.ascii.eqlIgnoreCase(std.mem.span(f), family)) return true;
        }
        var buf: [256]u8 = undefined;
        const sfnt = face.name(&buf) catch "";
        return sfnt.len > 0 and std.ascii.eqlIgnoreCase(sfnt, family);
    }

    fn faceStyleName(face: *const Face) []const u8 {
        const ptr = face.face.handle.*.style_name orelse return "";
        return std.mem.span(ptr);
    }

    fn styleMatches(face: *const Face, desc: Descriptor) bool {
        const style_name = faceStyleName(face);
        if (desc.style) |style| {
            return std.ascii.eqlIgnoreCase(style_name, style);
        }

        const flags = face.face.handle.*.style_flags;
        const bold = flags & freetype.c.FT_STYLE_FLAG_BOLD != 0;
        const italic = flags & freetype.c.FT_STYLE_FLAG_ITALIC != 0;
        return bold == desc.bold and italic == desc.italic;
    }

    fn desiredStyles(desc: Descriptor) []const [:0]const u8 {
        if (desc.style) |style| return &.{style};
        if (desc.bold) {
            if (desc.italic) return &.{ "bold italic", "bold", "italic", "oblique" };
            return &.{ "bold", "upright" };
        }
        if (desc.italic) return &.{ "italic", "regular", "oblique" };
        return &.{ "regular", "upright" };
    }
};

test "descriptor hash" {
    const testing = std.testing;

    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}

test "descriptor hash family names" {
    const testing = std.testing;

    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}

test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    var face = (try it.next()).?;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}

test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext sorting" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//
    // FIXME: Disabled for now because SF Pro is not available in CI
    //        The solution likely involves directly testing that the
    //        `sortMatchingDescriptors` function sorts a bundled test
    //        font correctly, instead of relying on the system fonts.
    if (true) return error.SkipZigTest;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();

    // We try to get a Regular, Italic, Bold, & Bold Italic version of SF Pro,
    // which should be installed on all Macs, and has many styles which makes
    // it a good test, since there will be many results for each discovery.

    // Regular
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular", name);
    }

    // Regular Italic
    //
    // NOTE: This makes sure that we don't accidentally prefer "Thin Italic",
    //       which we previously did, because it has a shorter name.
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular Italic", name);
    }

    // Bold
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold", name);
    }

    // Bold Italic
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold Italic", name);
    }
}

test "windows" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    // Arial ships on every stock Windows install.
    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12 });
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));

    const cases = [_]struct {
        bold: bool = false,
        italic: bool = false,
        expected_style: []const u8,
    }{
        .{ .expected_style = "Regular" },
        .{ .bold = true, .expected_style = "Bold" },
        .{ .italic = true, .expected_style = "Italic" },
        .{ .bold = true, .italic = true, .expected_style = "Bold Italic" },
    };
    for (cases) |case| {
        var style_it = try win.discover(alloc, .{
            .family = "Arial",
            .size = 12,
            .bold = case.bold,
            .italic = case.italic,
        });
        defer style_it.deinit();
        var style_face = (try style_it.next()) orelse return error.TestFontNotFound;
        defer style_face.deinit();
        const style_name = Windows.faceStyleName(&style_face.win.?.peek);
        try testing.expectEqualStrings(case.expected_style, style_name);
    }

    var missing_style_it = try win.discover(alloc, .{
        .family = "Arial",
        .style = "Ghostty Missing Style",
        .size = 12,
    });
    defer missing_style_it.deinit();
    try testing.expectEqual(null, try missing_style_it.next());
}

test "Windows DirectWrite UTF-16 scalar encoding" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [2]u16 = undefined;

    try testing.expectEqualSlices(
        u16,
        &.{0x9F98},
        try Windows.encodeScalarUtf16(0x9F98, &buf),
    );
    try testing.expectEqualSlices(
        u16,
        &.{ 0xD840, 0xDC00 },
        try Windows.encodeScalarUtf16(0x20000, &buf),
    );
    try testing.expectError(
        error.InvalidCodepoint,
        Windows.encodeScalarUtf16(0xD800, &buf),
    );
    try testing.expectError(
        error.InvalidCodepoint,
        Windows.encodeScalarUtf16(0x110000, &buf),
    );
}

test "Windows fallback loads a font from a UTF-8 path" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "日本語フォント", .default_dir);

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(cwd);
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_path);
    const source = try std.fs.path.join(alloc, &.{
        cwd,
        "src",
        "font",
        "res",
        "JetBrainsMonoNoNF-Regular.ttf",
    });
    defer alloc.free(source);
    const destination = try std.fs.path.join(alloc, &.{
        tmp_path,
        "日本語フォント",
        "確認用.ttf",
    });
    defer alloc.free(destination);
    try std.Io.Dir.copyFileAbsolute(source, destination, io, .{});

    const destination_z = try alloc.dupeZ(u8, destination);
    defer alloc.free(destination_z);
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var loaded = try Windows.loadFileFace(alloc, lib, destination_z, 0);
    try testing.expect(loaded.face.glyphIndex('A') != null);

    const deferred_path = alloc.dupeZ(u8, destination) catch |err| {
        loaded.face.deinit();
        if (loaded.data) |data| alloc.free(data);
        return err;
    };
    var deferred: DeferredFace = .{ .win = .{
        .path = deferred_path,
        .face_index = 0,
        .data = loaded.data,
        .variations = &.{},
        .peek = loaded.face,
        .presentation = .text,
        .alloc = alloc,
    } };
    var face = deferred.load(lib, .{ .size = .{ .points = 12 } }) catch |err| {
        deferred.deinit();
        return err;
    };
    deferred.deinit();
    defer face.deinit();
    try testing.expect(face.glyphIndex('A') != null);
}

test "Windows memory-backed deferred face owns loaded data" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(cwd);
    const path = try std.fs.path.join(alloc, &.{
        cwd,
        "src",
        "font",
        "res",
        "JetBrainsMonoNoNF-Regular.ttf",
    });
    defer alloc.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const size = std.math.cast(usize, (try file.stat(io)).size) orelse
        return error.FileTooBig;
    var reader = file.reader(io, &.{});
    const data = try reader.interface.readAlloc(alloc, size);

    var lib = Library.init(alloc) catch |err| {
        alloc.free(data);
        return err;
    };
    defer lib.deinit();
    var peek = Face.initMemory(
        lib,
        data,
        0,
        .{ .size = .{ .points = 12 } },
    ) catch |err| {
        alloc.free(data);
        return err;
    };
    const deferred_path = alloc.dupeZ(u8, path) catch |err| {
        peek.deinit();
        alloc.free(data);
        return err;
    };
    var deferred: DeferredFace = .{ .win = .{
        .path = deferred_path,
        .face_index = 0,
        .data = data,
        .variations = &.{},
        .peek = peek,
        .presentation = .text,
        .alloc = alloc,
    } };
    var face = deferred.load(lib, .{ .size = .{ .points = 12 } }) catch |err| {
        deferred.deinit();
        return err;
    };
    deferred.deinit();
    defer face.deinit();
    try testing.expect(face.glyphIndex('A') != null);
}

test "Windows DirectWrite fallback is serialized across threads" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = std.heap.page_allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var win = Windows.init(lib);
    defer win.deinit();
    const dwrite = if (win.dwrite) |*value| value else return error.DirectWriteUnavailable;

    const Context = struct {
        dwrite: *Windows.DirectWrite,
        lib: Library,
        codepoint: u32,
        ok: bool = false,

        fn run(self: *@This()) void {
            var deferred = self.dwrite.map(
                std.heap.page_allocator,
                self.lib,
                null,
                .{ .codepoint = self.codepoint, .size = 12 },
            ) catch return;
            if (deferred) |*face| {
                defer face.deinit();
                self.ok = face.hasCodepoint(self.codepoint, null);
            }
        }
    };

    var contexts = [_]Context{
        .{ .dwrite = dwrite, .lib = lib, .codepoint = 'A' },
        .{ .dwrite = dwrite, .lib = lib, .codepoint = 0x65E5 },
        .{ .dwrite = dwrite, .lib = lib, .codepoint = 0x9F98 },
        .{ .dwrite = dwrite, .lib = lib, .codepoint = 0x20000 },
    };
    var threads: [contexts.len]std.Thread = undefined;
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try .spawn(.{}, Context.run, .{context});
    }
    for (&threads) |*thread| thread.join();
    for (contexts) |context| try testing.expect(context.ok);
}

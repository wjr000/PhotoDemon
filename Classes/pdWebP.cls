VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "pdWebP"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'WebP Image Interface
'Copyright 2021-2021 by Tanner Helland
'Created: 22/September/21
'Last updated: 24/September/21
'Last update: animated WebP now supported (import only)
'
'LibWebP is a BSD-licensed WebP image support library.  It is developed and actively maintained by Google.
' Fortunately for PhotoDemon, it comes with a robust C interface and legacy compilation options, enabling
' support all the way back to Windows XP (hypothetically - testing on XP is still TODO).
'
'PhotoDemon historically used FreeImage to manage WebP files, but using libwebp directly allows for
' significantly better performance and feature support, including animated WebP files (which FreeImage
' does not support).
'
'Note that all features in this module rely on the libwebp binaries that ship with PhotoDemon.
' These features will not work if libwebp cannot be located.
'
'You can freely plug-in your own builds of libwebp and libwebpde/mux, but note that they must be built
' using cdecl exports and x86 only (obviously).  Note also that many exported APIs require us to pass an
' ABI identifier which may need to be updated against future library versions (to enable new library
' features, at least).
'
'Please refer to Plugin_WebP for details on initializing the various libraries; that is not handled here.
'
'This wrapper class uses a shorthand implementation of DispCallFunc originally written by Olaf Schmidt.
' Many thanks to Olaf, whose original version can be found here (link good as of Feb 2019):
' http://www.vbforums.com/showthread.php?781595-VB6-Call-Functions-By-Pointer-(Universall-DLL-Calls)&p=4795471&viewfull=1#post4795471
'
'Unless otherwise noted, all source code in this file is shared under a simplified BSD license.
' Full license details are available in the LICENSE.md file, or at https://photodemon.org/license/
'
'***************************************************************************

Option Explicit

'To aid debugging, you can activate "verbose" output; this will dump various bits of diagnostic info
' to the debug log.
Private Const WEBP_DEBUG_VERBOSE As Boolean = True

'Some exported APIs require passing ABI version numbers; confusingly, these exports are usually
' suffixed with "Internal"; see the class initialization function for details.
Private Const WEBP_DECODER_ABI_VERSION As Long = &H209& 'From decode.h
Private Const WEBP_DEMUX_ABI_VERSION As Long = &H107&   'From demux.h

Private Enum PD_VP8StatusCode
    VP8_STATUS_OK = 0
    VP8_STATUS_OUT_OF_MEMORY
    VP8_STATUS_INVALID_PARAM
    VP8_STATUS_BITSTREAM_ERROR
    VP8_STATUS_UNSUPPORTED_FEATURE
    VP8_STATUS_SUSPENDED
    VP8_STATUS_USER_ABORT
    VP8_STATUS_NOT_ENOUGH_DATA
End Enum

#If False Then
    Private Const VP8_STATUS_OK = 0, VP8_STATUS_OUT_OF_MEMORY = 0, VP8_STATUS_INVALID_PARAM = 0, VP8_STATUS_BITSTREAM_ERROR = 0, VP8_STATUS_UNSUPPORTED_FEATURE = 0, VP8_STATUS_SUSPENDED = 0, VP8_STATUS_USER_ABORT = 0, VP8_STATUS_NOT_ENOUGH_DATA = 0
#End If

Private Enum PD_WebPFormatFeature
    WEBP_FF_FORMAT_FLAGS    'bit-wise combination of WebPFeatureFlags corresponding to the 'VP8X' chunk (if present).
    WEBP_FF_CANVAS_WIDTH
    WEBP_FF_CANVAS_HEIGHT
    WEBP_FF_LOOP_COUNT      'only relevant for animated file
    WEBP_FF_BACKGROUND_COLOR    'idem.
    WEBP_FF_FRAME_COUNT     'Number of frames present in the demux object. In case of a partial demux, this is the number
                            ' of frames seen so far, with the last frame possibly being partial.
End Enum

#If False Then
    Private Const WEBP_FF_FORMAT_FLAGS = 0, WEBP_FF_CANVAS_WIDTH = 0, WEBP_FF_CANVAS_HEIGHT = 0, WEBP_FF_LOOP_COUNT = 0, WEBP_FF_BACKGROUND_COLOR = 0, WEBP_FF_FRAME_COUNT = 0
#End If

'VP8X Feature Flags (this chunk is optional in basic single-frame files)
Private Enum PD_WebPFeatureFlags
    ANIMATION_FLAG = &H2&
    XMP_FLAG = &H4&
    EXIF_FLAG = &H8&
    ALPHA_FLAG = &H10&
    ICCP_FLAG = &H20&
    ALL_VALID_FLAGS = &H3E&
End Enum

#If False Then
    Private Const ANIMATION_FLAG = &H2&, XMP_FLAG = &H4&, EXIF_FLAG = &H8&, ALPHA_FLAG = &H10&, ICCP_FLAG = &H20&, ALL_VALID_FLAGS = &H3E&
#End If

'Dispose method (animation only). Indicates how the area used by the current
' frame is to be treated before rendering the next frame on the canvas.
Private Enum PD_WebPMuxAnimDispose
    WEBP_MUX_DISPOSE_NONE         'Do not dispose.
    WEBP_MUX_DISPOSE_BACKGROUND   'Dispose to background color.
End Enum

#If False Then
    Private Const WEBP_MUX_DISPOSE_NONE = 0, WEBP_MUX_DISPOSE_BACKGROUND = 1
#End If

'Blend operation (animation only). Indicates how transparent pixels of the
' current frame are blended with those of the previous canvas.
Private Enum PD_WebPMuxAnimBlend
    WEBP_MUX_BLEND      'Blend.
    WEBP_MUX_NO_BLEND   'Do not blend.
End Enum

#If False Then
    Private Const WEBP_MUX_BLEND = 0, WEBP_MUX_NO_BLEND = 1
#End If

Private Enum PD_WEBP_CSP_MODE
    MODE_RGB = 0
    MODE_RGBA = 1
    MODE_BGR = 2
    MODE_BGRA = 3
    MODE_ARGB = 4
    MODE_RGBA_4444 = 5
    MODE_RGB_565 = 6
    'RGB-premultiplied transparent modes (alpha value is preserved)
    ' (names changed to work in VB)
    MODE_rgbAp = 7
    MODE_bgrAp = 8
    MODE_Argbp = 9
    MODE_rgbAp_4444 = 10
    'YUV modes must come after RGB ones.
    MODE_YUV = 11
    MODE_YUVA = 12  '// yuv 4:2:0
    MODE_LAST = 13
End Enum

#If False Then
    Private Const MODE_RGB = 0, MODE_RGBA = 1, MODE_BGR = 2, MODE_BGRA = 3, MODE_ARGB = 4, MODE_RGBA_4444 = 5, MODE_RGB_565 = 6
    Private Const MODE_rgbAp = 7, MODE_bgrAp = 8, MODE_Argbp = 9, MODE_rgbAp_4444 = 10
    Private Const MODE_YUV = 11, MODE_YUVA = 12, MODE_LAST = 13
#End If

'Various structs follow.  These all require use of the advanced decoding interface; the "quick" one
' can't supply these
Private Type PD_WebPBitstreamFeatures
    webpWidth As Long       'Width in pixels, as read from the bitstream.
    webpHeight As Long      'Height in pixels, as read from the bitstream.
    webHasAlpha As Long     'True if the bitstream contains an alpha channel.
    webpHasAnimation As Long 'True if the bitstream is an animation.
    webpFormat As Long      '0 = undefined (/mixed), 1 = lossy, 2 = lossless
    webpPadding(5) As Long  'padding for later use
End Type

'Animation options
Private Type PD_WebPAnimDecoderOptions
    'Output colorspace. Only the following modes are supported:
    '  MODE_RGBA, MODE_BGRA, MODE_rgbA and MODE_bgrA.
    color_mode As PD_WEBP_CSP_MODE
    use_threads As Long         'If true, use multi-threaded decoding.
    padding(7) As Long          '// Padding for later use.
End Type

'Global information about the animation
Private Type PD_WebPAnimInfo
    canvas_width As Long
    canvas_height As Long
    loop_count As Long
    bgcolor As Long
    frame_count As Long
    padding(4) As Long          '// padding for later use
End Type

'Note that regular WebP features reside in libwebp; animation features are in libwebpde/mux.

'libwebp uses a Google-specific toolchain for compilation, so we lean on their supplied makefile for building.
' This produces cdecl DLLs which we must wrap using DispCallFunc.
Private Declare Function DispCallFunc Lib "oleaut32" (ByVal pvInstance As Long, ByVal offsetinVft As Long, ByVal CallConv As Long, ByVal retTYP As Integer, ByVal paCNT As Long, ByRef paTypes As Integer, ByRef paValues As Long, ByRef retVAR As Variant) As Long
Private Declare Function GetProcAddress Lib "kernel32" (ByVal hModule As Long, ByVal lpProcName As String) As Long

'At load-time, we cache a number of proc addresses (required for passing through DispCallFunc).
' This saves us a little time vs calling GetProcAddress on each call.
Private Enum WebP_ProcAddress
    WebPAnimDecoderDelete
    WebPAnimDecoderGetInfo
    WebPAnimDecoderGetNext
    WebPAnimDecoderHasMoreFrames
    WebPAnimDecoderNew
    WebPAnimDecoderOptionsInit
    WebPAnimDecoderReset
    WebPDecodeBGRAInto
    WebPDemux
    WebPDemuxDelete
    WebPDemuxGetI
    WebPGetDecoderVersion
    WebPGetFeatures
    WebPGetInfo
    [last_address]
End Enum

Private m_ProcAddresses() As Long

'Rather than allocate new memory on each DispCallFunc invoke, just reuse a set of temp arrays declared
' to the maximum relevant size (see InitializeEngine, below).
Private Const MAX_PARAM_COUNT As Long = 8
Private m_vType() As Integer, m_vPtr() As Long

'Features of the current file follow
Private m_fileFeatures As PD_WebPBitstreamFeatures
Private m_imgWidth As Long, m_imgHeight As Long

'Many WebP features require a specialized demuxer object to retrieve.  If this handle is non-zero,
' a demuxer has been allocated.  You *MUST* free this with a call to WebPDemuxDelete().
Private m_hDemuxer As Long

'Animated files will fill this struct.  (Non-animated files WILL NOT.)
Private m_AnimationInfo As PD_WebPAnimInfo

Friend Function GetLibraryVersion() As Long
    GetLibraryVersion = CallCDeclW(WebPGetDecoderVersion, vbLong)
End Function

Friend Function HasAlpha() As Boolean
    HasAlpha = (m_fileFeatures.webHasAlpha <> 0)
End Function

Friend Function IsAnimated() As Boolean
    IsAnimated = (m_fileFeatures.webpHasAnimation <> 0)
End Function

'Load a WebP file from memory.  This is used exclusively in PD because libwebp does *not* provide any
' direct file-read functions.  (All load functions operate on pointers.)
'
'Anyway, we leave it to the caller to figure out how they want to allocate+store the data.  We just need
' the base pointer and the size, which are blindly relayed to libwebp.
'
'The filename is only passed so that we can name the base layer (in a non-animated file)
Friend Function LoadWebP_FromMemory(ByRef srcFile As String, ByVal pData As Long, ByVal sizeOfDataInBytes As Long, ByRef dstImage As pdImage, ByRef dstDIB As pdDIB) As Boolean
    
    Const FUNC_NAME = "LoadWebP_FromMemory"
    
    LoadWebP_FromMemory = False
    Dim webpResult As PD_VP8StatusCode
    
    'Start by querying basic features, like "is the file animated"
    webpResult = CallCDeclW(WebPGetFeatures, vbLong, pData, sizeOfDataInBytes, VarPtr(m_fileFeatures), WEBP_DECODER_ABI_VERSION)
    If (webpResult <> VP8_STATUS_OK) Then
        InternalError FUNC_NAME, "WebPGetFeaturesInternal", webpResult
        Exit Function
    End If
    
    If WEBP_DEBUG_VERBOSE Then PDDebug.LogAction "WebP file features: animated: " & (m_fileFeatures.webpHasAnimation <> 0) & ", alpha: " & (m_fileFeatures.webHasAlpha <> 0) & ", lossless: " & (m_fileFeatures.webpFormat = 2)
    m_imgWidth = m_fileFeatures.webpWidth
    m_imgHeight = m_fileFeatures.webpHeight
    If WEBP_DEBUG_VERBOSE Then PDDebug.LogAction "WebP image size: " & m_imgWidth & "x" & m_imgHeight
    
    'Perform basic validation
    If (m_imgWidth < 1) Or (m_imgHeight < 1) Then
        InternalError FUNC_NAME, "bad image width/height"
        Exit Function
    End If
    
    'Unfortunately for us, libwebp has a complex and poorly conceived API design.  You'd think that our
    ' previous call to WebPGetFeatures would tell us all the critical features of the file, but no,
    ' it doesn't.  Instead, we now need to create a demuxer object, which reports its own feature
    ' collection (that overlaps the other feature set in some ways but not all ways, sigh).
    '
    'Note that failure to create a demuxer isn't necessarily a deal-breaker - but it does mean
    ' that we can't query important features like ICC profiles.
    If (Not InitializeDemuxer(pData, sizeOfDataInBytes)) Then InternalError FUNC_NAME, "couldn't allocate demuxer; attempting to load anyway"
    
    'If a demuxer *was* created successfully, use feature flags to look for an ICC profile
    Dim imgHasColorProfile As Boolean
    If (m_hDemuxer <> 0) Then
        
        Dim curImageFeatureFlags As PD_WebPFeatureFlags
        curImageFeatureFlags = CallCDeclW(WebPDemuxGetI, vbLong, m_hDemuxer, WEBP_FF_FORMAT_FLAGS)
        imgHasColorProfile = (curImageFeatureFlags And ICCP_FLAG)
        If WEBP_DEBUG_VERBOSE Then PDDebug.LogAction "WebP features; ICC: " & CBool(curImageFeatureFlags And ICCP_FLAG) & ", EXIF: " & CBool(curImageFeatureFlags And EXIF_FLAG) & ", XMP: " & CBool(curImageFeatureFlags And XMP_FLAG)
        
        'TODO: find WebP images "in the wild" with embedded ICC profiles so I can test retrieval
        
    End If
    
    'If we're still here, the file looks readable.  How we proceed depends on whether the image is
    ' animated or not.  (Animated images produce multiple layers.)
    
    'Attempt animated image import first, so that if something goes wrong we can fall back to single-frame retrieval
    Dim animationLoaded As Boolean: animationLoaded = False
    If (m_fileFeatures.webpHasAnimation <> 0) Then animationLoaded = LoadAnimatedWebP(srcFile, pData, sizeOfDataInBytes, dstImage, dstDIB)
    
    If animationLoaded Then
    
        'Our work here is done!  Note that we don't exit immediately, as the end of the function may
        ' need to clean-up some libwebp objects before exiting
        LoadWebP_FromMemory = True
    
    'If the underlying image is *not* animated (or if animation import failed), load the file as
    ' a single-frame instance.
    Else
    
        'This file is not animated.  Load it normally.
        
        'Create the destination surface.  (We can decode the WebP directly into this buffer, yay!)
        Set dstDIB = New pdDIB
        dstDIB.CreateBlank m_imgWidth, m_imgHeight, 32, 255, 255
        
        'Decode the image directly into the buffer
        Dim decodeOK As Boolean
        With dstDIB
            decodeOK = (CallCDeclW(WebPDecodeBGRAInto, vbLong, pData, sizeOfDataInBytes, .GetDIBPointer, .GetDIBStride * .GetDIBHeight, .GetDIBStride) <> 0)
        End With
        
        'Ensure success (this particular function returns 0 when unsuccessful, per the docs)
        If decodeOK Then
            
            'TODO: get libwebp to paint in premultiplied mode
            dstDIB.SetAlphaPremultiplication True
            
            'Initialize the target layer
            Dim newLayerID As Long
            newLayerID = dstImage.CreateBlankLayer()
            
            Dim tmpLayer As pdLayer
            Set tmpLayer = dstImage.GetLayerByID(newLayerID)
            tmpLayer.InitializeNewLayer PDL_Image, Files.FileGetName(srcFile, True), dstDIB, False
            tmpLayer.SetLayerVisibility True
            
            'Finish initializing the target image
            dstImage.Width = m_imgWidth
            dstImage.Height = m_imgHeight
            
            'WebP files do not provide a direct way to set DPI
            dstImage.SetDPI 72, 72
            
            dstImage.NotifyImageChanged UNDO_Everything
            LoadWebP_FromMemory = True
            
        'decoding pixel data failed - not much we can do but abort completely
        Else
            InternalError FUNC_NAME, "bad WebPDecodeBGRAInto"
            Set dstDIB = Nothing
            LoadWebP_FromMemory = False
        End If
    
    '/end single-frame load process
    End If
    
    'Before exiting, free any allocated demuxer(s)
    FreeDemuxer
    
End Function

'Parse and import all frames from an animated WebP image.  Do *not* call without verifying that the
' passed image is, actually, an animated WebP.
Private Function LoadAnimatedWebP(ByRef srcFile As String, ByVal pData As Long, ByVal sizeOfDataInBytes As Long, ByRef dstImage As pdImage, ByRef dstDIB As pdDIB) As Boolean
    
    LoadAnimatedWebP = False
    
    'Due to the design of libwebp (and animation functions being shunted into an entirely different
    ' library, libwebpdemuxer), animated images require a unique import process.
    Const FUNC_NAME As String = "LoadAnimatedWebP"
    
    'If a demuxer hasn't been allocated, allocate one now.  (Note that there is no harm in calling
    ' this if a demuxer already exists - we'll simply reuse the current class-level one.)
    If (Not InitializeDemuxer(pData, sizeOfDataInBytes)) Then
        InternalError FUNC_NAME, "couldn't allocate demuxer; abandoning animation import"
        LoadAnimatedWebP = False
        Exit Function
    End If
    
    'We are now guaranteed a valid demuxer in m_hDemuxer.
    
    'Retrieve the number of frames and perform basic sanity checks.
    Dim numFrames As Long
    numFrames = CallCDeclW(WebPDemuxGetI, vbLong, m_hDemuxer, WEBP_FF_FRAME_COUNT)
    If (numFrames > 1) Then
    
        'Next, we need to initialize an animation decoder options struct.  The library suggests
        ' allowing the library to initialize the struct for us, which... whatever, I guess?
        Dim animDecodeOptions As PD_WebPAnimDecoderOptions
        If (CallCDeclW(WebPAnimDecoderOptionsInit, vbLong, VarPtr(animDecodeOptions), WEBP_DEMUX_ABI_VERSION) = 0) Then
            InternalError FUNC_NAME, "WebPAnimDecoderOptionsInit"
            GoTo AnimationBroken
        End If
        
        'Set the animation decoder options to decode directly to premultiplied BGRA...
        animDecodeOptions.color_mode = MODE_bgrAp
        
        '...and explicitly allow multi-thread decoding on relevant systems
        Debug.Print animDecodeOptions.use_threads, "use threads?"
        If (OS.LogicalCoreCount > 1) Then animDecodeOptions.use_threads = 1 Else animDecodeOptions.use_threads = 0
        
        '...and finally, use the options struct to initialize an actual decoder object
        Dim unionPtrAndLen(0 To 1) As Long
        unionPtrAndLen(0) = pData
        unionPtrAndLen(1) = sizeOfDataInBytes
        
        Dim animDecoder As Long
        animDecoder = CallCDeclW(WebPAnimDecoderNew, vbLong, VarPtr(unionPtrAndLen(0)), VarPtr(animDecodeOptions), WEBP_DEMUX_ABI_VERSION)
        
        'Further animation decoding requires a valid decoder; without one, we have to abandon ship
        If (animDecoder = 0) Then
            InternalError FUNC_NAME, "WebPAnimDecoderNew"
            GoTo AnimationBroken
        End If
        
        'Retrieve global animation info, like final canvas size and loop count
        If (CallCDeclW(WebPAnimDecoderGetInfo, vbLong, animDecoder, VarPtr(m_AnimationInfo)) = 0) Then
            InternalError FUNC_NAME, "WebPAnimDecoderGetInfo"
            GoTo AnimationBroken
        End If
        
        If WEBP_DEBUG_VERBOSE Then PDDebug.LogAction "animation frame count: " & m_AnimationInfo.frame_count & ", loop count: " & m_AnimationInfo.loop_count & ", bgcolor: " & Hex$(m_AnimationInfo.bgcolor)
        
        'The animation canvas size should match the original size retrieve in our parent function,
        ' but if (for some reason?) they don't, we'll defer to the animation canvas settings.
        dstImage.Width = m_AnimationInfo.canvas_width
        dstImage.Height = m_AnimationInfo.canvas_height
        
        'WebP files do not provide a direct way to store DPI (although you could hide DPI settings in
        ' EXIF or XMP metadata, if you really wanted to), but PD expects DPI values on all incoming
        ' pdImage objects - so set arbitrary defaults now.
        dstImage.SetDPI 72, 72
        
        'We also need to flag the underlying format in advance, since it changes the way layer
        ' names are assigned (animation layers are called "frames" instead of "pages"
        dstImage.SetOriginalFileFormat PDIF_WEBP
        
        'We also need to store the animation loop count inside the parent object
        dstImage.ImgStorage.AddEntry "animation-loop-count", Trim$(Str$(m_AnimationInfo.loop_count))
        
        'With all global options stored, we can now start iterating frames.  (Individual frame times
        ' will be retrieved as part of this process.)
        Dim idxFrame As Long, numFramesOK As Long
        For idxFrame = 0 To m_AnimationInfo.frame_count - 1
            
            'Yes, this text uses "page" instead of "frame" - this is purely to reduce localization burdens
            Message "Loading page %1 of %2...", CStr(idxFrame + 1), m_AnimationInfo.frame_count, "DONOTLOG"
            
            'Failsafe check to ensure the decoder has more frames for us
            If (CallCDeclW(WebPAnimDecoderHasMoreFrames, vbLong, animDecoder) <> 0) Then
                
                'Get the next frame.  Two values are returned: a pointer to a constructed 32-bpp buffer
                ' of size canvaswidth * canvasheight (managed by libwebpdemux), and a timestamp for this
                ' frame (in ms, like APNG, not cs like GIF)
                Dim ptrPixels As Long, frameTimestamp As Long, lastFrameTimestamp As Long, frameTimeInMS As Long
                ptrPixels = 0: frameTimestamp = lastFrameTimestamp
                
                If (CallCDeclW(WebPAnimDecoderGetNext, vbLong, animDecoder, VarPtr(ptrPixels), VarPtr(frameTimestamp)) <> 0) Then
                    
                    'Success!  Create a new layer in the destination image, then copy the pixel data and
                    ' timestamp into it.
                    Dim newLayerID As Long, newLayerName As String, tmpLayer As pdLayer
                    newLayerID = dstImage.CreateBlankLayer()
                    Set tmpLayer = dstImage.GetLayerByID(newLayerID)
                    newLayerName = Layers.GenerateInitialLayerName(vbNullString, vbNullString, True, dstImage, dstDIB, idxFrame)
                    tmpLayer.InitializeNewLayer PDL_Image, newLayerName, Nothing, True
                    tmpLayer.SetLayerVisibility (idxFrame = 0)
                    
                    If (tmpLayer.layerDIB Is Nothing) Then Set tmpLayer.layerDIB = New pdDIB
                    tmpLayer.layerDIB.CreateBlank m_AnimationInfo.canvas_width, m_AnimationInfo.canvas_height, 32, 0, 0
                    CopyMemoryStrict tmpLayer.layerDIB.GetDIBPointer, ptrPixels, tmpLayer.layerDIB.GetDIBStride * tmpLayer.layerDIB.GetDIBHeight
                    
                    'We explicitly request premultiplied data, so we don't need to manually premultiply now
                    tmpLayer.layerDIB.SetInitialAlphaPremultiplicationState True
                    
                    'As part of storing frametime, update the layer's name with ([time] ms) at the end
                    frameTimeInMS = frameTimestamp - lastFrameTimestamp
                    tmpLayer.SetLayerFrameTimeInMS frameTimeInMS
                    tmpLayer.SetLayerName tmpLayer.GetLayerName & " (" & CStr(frameTimeInMS) & "ms)"
                    lastFrameTimestamp = frameTimestamp
                    tmpLayer.NotifyOfDestructiveChanges
                    
                    'Track how many frames we've successfully loaded
                    numFramesOK = numFramesOK + 1
                
                'Couldn't get next frame
                Else
                    InternalError FUNC_NAME, "WebPAnimDecoderGetNext: unexpected fail"
                End If
            
            '/decoder doesn't have more frames, despite all frames not being read
            Else
                InternalError FUNC_NAME, "WebPAnimDecoderHasMoreFrames: unexpected fail"
            End If
                
        Next idxFrame
        
        'Reset the underlying iterator before continuing
        CallCDeclW WebPAnimDecoderReset, vbLong, animDecoder
        
        'Report success if at least one frame was retrieved correctly
        LoadAnimatedWebP = (numFramesOK > 0)
        If LoadAnimatedWebP Then dstImage.NotifyImageChanged UNDO_Everything
           
    '/animation frames <= 1
    Else
        InternalError FUNC_NAME, "only one animation frame found; reverting to static load process"
    End If
    
'Animated files can break in a lot (seriously, a LOT) of ways.  Because VB doesn't have normal try/catch syntax,
' we're stuck with GOTOs.  Broken animation files will divert here, which allows us to continue loading the
' file as a non-animated image while also freeing any animation objects we created along the way.
AnimationBroken:

    'Free a decoder object, if any
    If (animDecoder <> 0) Then
        CallCDeclW WebPAnimDecoderDelete, vbEmpty, animDecoder
        animDecoder = 0
    End If
    
    'Free the underlying demuxer (it isn't required by the single-frame loader)
    FreeDemuxer
    
End Function

Private Sub FreeDemuxer()
    If (m_hDemuxer <> 0) Then
        CallCDeclW WebPDemuxDelete, vbEmpty, m_hDemuxer
        m_hDemuxer = 0
    End If
End Sub

Private Function InitializeDemuxer(ByVal pWebPData As Long, ByVal pWebPDataLenB As Long) As Boolean
    
    'If we already have a demuxer, reuse it
    If (m_hDemuxer <> 0) Then
        InitializeDemuxer = True
    Else
        
        'The demux API takes a *WebPData as input; this is a simple union of data pointer and size
        Dim webpDataStruct(0 To 1) As Long
        webpDataStruct(0) = pWebPData
        webpDataStruct(1) = pWebPDataLenB
        
        m_hDemuxer = CallCDeclW(WebPDemux, vbLong, VarPtr(webpDataStruct(0)), 0&, 0&, WEBP_DEMUX_ABI_VERSION)
        InitializeDemuxer = (m_hDemuxer <> 0)
        If WEBP_DEBUG_VERBOSE Then PDDebug.LogAction "Allocated demux object: " & m_hDemuxer
        
    End If
    
End Function

'DispCallFunc wrapper originally by Olaf Schmidt, with a few minor modifications; see the top of this class
' for a link to his original, unmodified version
Private Function CallCDeclW(ByVal lProc As WebP_ProcAddress, ByVal fRetType As VbVarType, ParamArray pa() As Variant) As Variant

    Dim i As Long, vTemp() As Variant, hResult As Long
    
    Dim numParams As Long
    If (UBound(pa) < LBound(pa)) Then numParams = 0 Else numParams = UBound(pa) + 1
    
    If IsMissing(pa) Then
        ReDim vTemp(0) As Variant
    Else
        vTemp = pa 'make a copy of the params, to prevent problems with VT_Byref-Members in the ParamArray
    End If
    
    For i = 0 To numParams - 1
        If VarType(pa(i)) = vbString Then vTemp(i) = StrPtr(pa(i))
        m_vType(i) = VarType(vTemp(i))
        m_vPtr(i) = VarPtr(vTemp(i))
    Next i
    
    Const CC_CDECL As Long = 1
    hResult = DispCallFunc(0, m_ProcAddresses(lProc), CC_CDECL, fRetType, i, m_vType(0), m_vPtr(0), CallCDeclW)
    
End Function

Private Sub InternalError(ByVal funcName As String, Optional ByRef errString As String = vbNullString, Optional ByVal libReturn As PD_VP8StatusCode = VP8_STATUS_OK)
    funcName = "pdWebP." & funcName & "() "
    If (libReturn <> VP8_STATUS_OK) Then
        PDDebug.LogAction funcName & "returned error #" & libReturn & "(" & errString & ")", PDM_External_Lib
    Else
        PDDebug.LogAction funcName & " error:" & errString, PDM_External_Lib
    End If
End Sub

Private Sub Class_Initialize()

    'Pre-load all relevant proc addresses
    ReDim m_ProcAddresses(0 To [last_address] - 1) As Long
    m_ProcAddresses(WebPAnimDecoderDelete) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderDelete")
    m_ProcAddresses(WebPAnimDecoderGetInfo) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderGetInfo")
    m_ProcAddresses(WebPAnimDecoderGetNext) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderGetNext")
    m_ProcAddresses(WebPAnimDecoderHasMoreFrames) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderHasMoreFrames")
    m_ProcAddresses(WebPAnimDecoderNew) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderNewInternal")
    m_ProcAddresses(WebPAnimDecoderOptionsInit) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderOptionsInitInternal")
    m_ProcAddresses(WebPAnimDecoderReset) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPAnimDecoderReset")
    m_ProcAddresses(WebPDecodeBGRAInto) = GetProcAddress(Plugin_WebP.GetHandle_LibWebP(), "WebPDecodeBGRAInto")
    m_ProcAddresses(WebPDemux) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPDemuxInternal")
    m_ProcAddresses(WebPDemuxDelete) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPDemuxDelete")
    m_ProcAddresses(WebPDemuxGetI) = GetProcAddress(Plugin_WebP.GetHandle_LibWebPDemux(), "WebPDemuxGetI")
    m_ProcAddresses(WebPGetDecoderVersion) = GetProcAddress(Plugin_WebP.GetHandle_LibWebP(), "WebPGetDecoderVersion")
    m_ProcAddresses(WebPGetFeatures) = GetProcAddress(Plugin_WebP.GetHandle_LibWebP(), "WebPGetFeaturesInternal")
    m_ProcAddresses(WebPGetInfo) = GetProcAddress(Plugin_WebP.GetHandle_LibWebP(), "WebPGetInfo")
    
    'Initialize all module-level arrays
    ReDim m_vType(0 To MAX_PARAM_COUNT - 1) As Integer
    ReDim m_vPtr(0 To MAX_PARAM_COUNT - 1) As Long
    
End Sub

Private Sub Class_Terminate()
    FreeDemuxer
End Sub
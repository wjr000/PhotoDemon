Attribute VB_Name = "Image_Autosave_Handler"
'***************************************************************************
'Image Autosave Handler
'Copyright �2013-2014 by Tanner Helland
'Created: 18/January/14
'Last updated: 21/May/14
'Last update: finish work on Autosave engine rewrite.  The Autosave engine can now do something absolutely kick-ass:
'              it can restruct the entire original image state, including the full Undo/Redo stack (allowing the user
'              to quite literally pick up wherever they left off).
'
'PhotoDemon's Autosave engine is closely tied to the pdUndo class, so some understanding of that class is necessary
' to appreciate how this module operates.
'
'All Undo/Redo data is saved to the hard drive, in a temp folder of the user's choosing (the Windows temp folder
' by default).  The data is cleared whenever an image is unloaded, and an extra pass is made at program shutdown
' "just to be safe".
'
'In the event of an unclean shutdown, this module searches the temp folder for any PhotoDemon-specific data.  If
' some is found, the user is given a choice to restore those files.  If the user declines, that data is wiped
' (to prevent future unclean shutdown checks from re-detecting it).
'
'As part of its Autosave functionality, this module also handles the creation and subsequent destruction of a
' "clean shutdown" file.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'A collection of valid Autosave XML entries in the user's Data\Autosave folder.  In all but the worst-case
' scenarios (e.g. program failure during generating Undo/Redo data), these *should* correspond to raw image
' data in the Undo/Redo list.
Public Type AutosaveXML
    xmlPath As String
    parentImageID As Long
    friendlyName As String
    originalPath As String
    undoStackHeight As Long
    undoStackAbsoluteMaximum As Long
    undoStackPointer As Long
    undoNumAtLastSave As Long
End Type

'Collection of Autosave XML entries found
Private m_numOfXMLFound As Long
Private m_XmlEntries() As AutosaveXML

'Check to make sure the last program shutdown was clean.  If it was, return TRUE (and write out a new safe shutdown file).
' If it was not, return FALSE.
Public Function wasLastShutdownClean() As Boolean

    Dim safeShutdownPath As String
    safeShutdownPath = g_UserPreferences.getPresetPath & "SafeShutdown.xml"
    
    'If a previous program session terminated unexpectedly, its safe shutdown file will still be present
    If FileExist(safeShutdownPath) Then
    
        wasLastShutdownClean = False

    'The previous shutdown was clean.  Write a new safe shutdown file.
    Else
    
        Dim xmlEngine As pdXML
        Set xmlEngine = New pdXML
        
        xmlEngine.prepareNewXML "Safe shutdown"
        
        xmlEngine.writeBlankLine
        xmlEngine.writeComment "This file is used to see if the previous PhotoDemon session terminated unexpectedly."
        xmlEngine.writeBlankLine
        xmlEngine.writeTag "SessionDate", Format$(Now, "Long Date")
        xmlEngine.writeTag "SessionTime", Format$(Now, "h:mm AMPM")
        xmlEngine.writeBlankLine
        
        xmlEngine.writeXMLToFile safeShutdownPath
        
        wasLastShutdownClean = True
    
    End If
    
    
End Function

'If the program has shut itself down without incident, the last thing it does will be notifying this sub.
' (This sub clears the safe shutdown file.)
Public Sub notifyCleanShutdown()
    
    Dim safeShutdownPath As String
    safeShutdownPath = g_UserPreferences.getPresetPath & "SafeShutdown.xml"
    
    If FileExist(safeShutdownPath) Then Kill safeShutdownPath

End Sub

'After an unclean shutdown is detected, this function can be called to search the temp directory for saveable Undo/Redo data.
' It will return a value larger than 0 if Undo/Redo data was found.
Public Function saveableImagesPresent() As Long

    'Search the temporary folder for any files matching PhotoDemon's Undo/Redo file pattern.  Because PD's Undo/Redo engine
    ' is awesome, it automatically saves very nice Undo XML files that contain key data for each pdImage opened by the program.
    ' In the event of an unsafe shutdown, these XML files help us easily reconstruct any "lost" images.
    
    'Note: the pattern of PhotoDemon's Undo XML summary files is:
    ' g_UserPreferences.GetTempPath & "~PDU_StackSummary_" & parentPDImage.imageID & "_.pdtmp"
    
    'Reset our XML detection arrays
    m_numOfXMLFound = 0
    ReDim m_XmlEntries(0 To 9) As AutosaveXML
    
    'We'll use PD's standard XML engine to validate any discovered autosave entries
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    
    'Retrieve the first matching file from the folder (if any)
    Dim chkFile As String
    chkFile = Dir(g_UserPreferences.GetTempPath & "~PDU_StackSummary_*_.pdtmp", vbNormal)
    
    'Continue checking potential autosave XML entries until all have been analyzed
    Do While Len(chkFile) > 0
    
        'First, make sure the file actually contains XML data
        If xmlEngine.loadXMLFile(g_UserPreferences.GetTempPath & chkFile) Then
        
            'If it does, make sure the XML data is valid, and that at least one Undo entry is listed in the file
            If xmlEngine.isPDDataType("Undo stack") And xmlEngine.validateLoadedXMLData("pdUndoVersion") Then
            
                'The file checks out!  Add it to our XML entries array
                With m_XmlEntries(m_numOfXMLFound)
                    .xmlPath = g_UserPreferences.GetTempPath & chkFile
                    .friendlyName = xmlEngine.getUniqueTag_String("friendlyName")
                    .originalPath = xmlEngine.getUniqueTag_String("originalPath")
                    .parentImageID = xmlEngine.getUniqueTag_Long("imageID", -1)
                    .undoNumAtLastSave = xmlEngine.getUniqueTag_Long("UndoNumAtLastSave", 0)
                    .undoStackAbsoluteMaximum = xmlEngine.getUniqueTag_Long("StackAbsoluteMaximum", 0)
                    .undoStackHeight = xmlEngine.getUniqueTag_Long("StackHeight", 1)
                    .undoStackPointer = xmlEngine.getUniqueTag_Long("CurrentStackPointer", 0)
                End With
                
                'Increment the "number found" counter and resize the array as necessary
                m_numOfXMLFound = m_numOfXMLFound + 1
                If m_numOfXMLFound > UBound(m_XmlEntries) Then
                    ReDim Preserve m_XmlEntries(0 To (UBound(m_XmlEntries) + 1) * 2) As AutosaveXML
                End If
                
            End If
            
        End If
        
        'Check the next file in the list
        chkFile = Dir
        
    Loop
    
    'Trim the XML array to its smallest relevant size, then return the number of images found
    ReDim Preserve m_XmlEntries(0 To m_numOfXMLFound) As AutosaveXML
    
    saveableImagesPresent = m_numOfXMLFound

End Function

'If the user declines to restore old AutoSave data, purge it from the system (to prevent it from showing up in future searches).
Public Sub purgeOldAutosaveData()
    
    Message "Purging old autosave data..."
    
    'Create a dummy pdUndo object.  This object will help us generate relevant filenames using PD's standard Undo filename formula.
    Dim tmpUndoEngine As pdUndo
    Set tmpUndoEngine = New pdUndo
    
    Dim tmpFilename As String
    Dim i As Long, j As Long
    
    'Loop through all XML files found.  We will not only be deleting the XML files themselves, but also any child
    ' files they may reference
    For i = 0 To m_numOfXMLFound - 1
    
        'Delete all possible child references for this image.
        For j = 0 To m_XmlEntries(i).undoStackAbsoluteMaximum
        
            tmpFilename = tmpUndoEngine.generateUndoFilenameExternal(m_XmlEntries(i).parentImageID, j)
        
            'Check image data first...
            If FileExist(tmpFilename) Then Kill tmpFilename
        
            '...followed by layer data
            If FileExist(tmpFilename & ".layer") Then Kill tmpFilename & ".layer"
        
            '...followed by selection data
            If FileExist(tmpFilename & ".selection") Then Kill tmpFilename & ".selection"
        
        Next j
        
        'Finally, kill the Autosave XML file and preview image associated with this entry
        If FileExist(m_XmlEntries(i).xmlPath) Then Kill m_XmlEntries(i).xmlPath
        If FileExist(m_XmlEntries(i).xmlPath & ".asp") Then Kill m_XmlEntries(i).xmlPath & ".asp"
    
    Next i
    
    'As a nice gesture, release any module-level data associated with the Autosave engine
    m_numOfXMLFound = 0
    ReDim m_XmlEntries(0) As AutosaveXML
    
End Sub

'External functions can retrieve a copy of the XML autosave entries we've found by using this function.
Public Function getXMLAutosaveEntries(ByRef autosaveArray() As AutosaveXML, ByRef autosaveCount As Long) As Boolean

    ReDim autosaveArray(0 To m_numOfXMLFound - 1) As AutosaveXML
    autosaveCount = m_numOfXMLFound
    
    Dim i As Long
    For i = 0 To autosaveCount - 1
        autosaveArray(i) = m_XmlEntries(i)
    Next i
    
    getXMLAutosaveEntries = True
    
End Function

'After any autosave images have been loaded into PD, call this function to replace those images' data (such as "location on disk")
' with information from the Autosave XML files.
Public Sub alignLoadedImageWithAutosave(ByRef srcPDImage As pdImage)

    Dim i As Long
    
    'Make sure the image loaded successfully
    If Not (srcPDImage Is Nothing) Then
    
        If srcPDImage.IsActive Then
        
            'Find a corresponding Autosave XML file for this image (if one exists)
            For i = 0 To m_numOfXMLFound - 1
            
                'If this file's location on disk matches the binary buffer associated with a given XML entry,
                ' ask the pdImage object to rewrite its internal data to match the XML file.
                If StrComp(srcPDImage.locationOnDisk, m_XmlEntries(i).xmlPath, vbTextCompare) = 0 Then
                    srcPDImage.readExternalData m_XmlEntries(i).xmlPath
                    Exit For
                End If
            
            Next i
        
        End If
    
    End If
    
End Sub

'If the user opts to restore one (or more) autosave entries, PD's main form will pass the list of XML files
' to this function.  It is our job to then load those files.
Public Sub loadTheseAutosaveFiles(ByRef fullXMLList() As AutosaveXML)

    Dim i As Long, newImageID As Long, oldImageID As Long
    Dim autosaveFile(0) As String
    
    'Before starting our processing loop, create a dummy pdUndo object.  This object will help us generate
    ' relevant filenames using PD's standard Undo filename formula.
    Dim tmpUndoEngine As pdUndo
    Set tmpUndoEngine = New pdUndo
    
    'An XML engine will be used to update each image's new Undo/Redo engine so that it exactly matches the
    ' state of its original Undo/Redo engine.
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    
    'Process each XML entry in turn.  Because of the way we are reconstructing the Undo entries, we can't load
    ' all the files in a single LoadFileAsNewImage request (despite it supporting an array of filenames).  Instead,
    ' we must load each image individually, do a bunch of processing to the image (and its Undo files) to restore
    ' it's proper image state, *then* move on to the next image.
    For i = 0 To UBound(fullXMLList)
    
        'Before doing anything else, we are going to rename the Undo files associated with this Autosave entry.
        ' PD assigns image IDs sequentially in each session, starting with image ID #1.  Because the image ID is immutable
        ' (it corresponds to the image's location in the master pdImages() array), we cannot simply change it to match
        ' the ID of the Undo files - instead, we must rename the Undo files to match the new image ID.
        newImageID = i + 1
        oldImageID = fullXMLList(i).parentImageID
        
        'If the image's new ID does not match its original one, rename all Undo files to match
        If newImageID <> oldImageID Then renameAllUndoFiles fullXMLList(i), newImageID, oldImageID
        
        'Make a copy of the current Undo XML file for this image, as it will be overwritten as soon as we load the first
        ' Undo entry as a new image.
        xmlEngine.loadXMLFile fullXMLList(i).xmlPath
        
        'We now have everything we need.  Load the base Undo entry as a new image.
        autosaveFile(0) = tmpUndoEngine.generateUndoFilenameExternal(newImageID, 0)
        LoadFileAsNewImage autosaveFile, False, fullXMLList(i).friendlyName, fullXMLList(i).friendlyName
        
        'The new image has been successfully noted, but we must now overwrite some of the data PD has assigned it with
        ' its original data (such as its "location on disk", which should reflect its original location - not its
        ' temporary file location!)
        pdImages(g_CurrentImage).locationOnDisk = fullXMLList(i).originalPath
        pdImages(g_CurrentImage).originalFileNameAndExtension = fullXMLList(i).friendlyName
        
        'It is now time to artificially reconstruct the image's Undo/Redo stack, using the data from the autosave file.
        ' The Undo engine itself handles this step.
        If pdImages(g_CurrentImage).undoManager.reconstructStackFromExternalSource(xmlEngine.returnCurrentXMLString) Then
        
            'The Undo stack was reconstructed successfully.  Ask it to advance the stack pointer to its location from
            ' the last session.
            pdImages(g_CurrentImage).undoManager.moveToSpecificUndoPoint fullXMLList(i).undoStackPointer
            
            Message "Autosave reconstruction complete for %1", fullXMLList(i).friendlyName
        
        Else
            Message "Autosave could not be fully reconstructed.  Partial reconstruction attempted instead."
        End If
    
    Next i
    
End Sub

'loadTheseAutosaveFiles(), above, uses this function to rename Undo files so that they match a new image ID.
Private Sub renameAllUndoFiles(ByRef autosaveData As AutosaveXML, ByVal newImageID As Long, ByVal oldImageID As Long)

    Dim oldFilename As String, newFilename As String
    
    'Before starting our processing loop, create a dummy pdUndo object.  This object will help us generate
    ' relevant filenames using PD's standard Undo filename formula.
    Dim tmpUndoEngine As pdUndo
    Set tmpUndoEngine = New pdUndo
    
    'The autosaveData object knows how many autosave files are available
    Dim i As Long
    For i = 0 To autosaveData.undoStackAbsoluteMaximum
    
        oldFilename = tmpUndoEngine.generateUndoFilenameExternal(oldImageID, i)
        newFilename = tmpUndoEngine.generateUndoFilenameExternal(newImageID, i)
        
        'Check image data first...
        If FileExist(oldFilename) Then
            If FileExist(newFilename) Then Kill newFilename
            Name oldFilename As newFilename
        End If
        
        '...followed by layer data
        If FileExist(oldFilename & ".layer") Then
            If FileExist(newFilename & ".layer") Then Kill newFilename & ".layer"
            Name oldFilename & ".layer" As newFilename & ".layer"
        End If
        
        '...followed by selection data
        If FileExist(oldFilename & ".selection") Then
            If FileExist(newFilename & ".selection") Then Kill newFilename & ".selection"
            Name oldFilename & ".selection" As newFilename & ".selection"
        End If
        
    Next i

End Sub

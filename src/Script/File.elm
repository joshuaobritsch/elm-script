module Script.File exposing
    ( Error
    , Existence(..)
    , File
    , asReadOnly
    , asWriteOnly
    , checkExistence
    , copy
    , copyInto
    , delete
    , move
    , moveInto
    , name
    , path
    , read
    , write
    , writeTo
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Script
import Script.Directory as Directory exposing (Directory)
import Script.FileInfo as FileInfo
import Script.Internal as Internal exposing (Flags)
import Script.Path as Path
import Script.Permissions exposing (Read, ReadOnly, Writable, Write, WriteOnly)


type alias File p =
    Internal.File p


type alias Error =
    { message : String
    }


type Existence
    = Exists
    | DoesNotExist
    | IsNotAFile


errorDecoder : Decoder Error
errorDecoder =
    Decode.map Error (Decode.field "message" Decode.string)


name : File p -> String
name (Internal.File filePath) =
    Path.name filePath


asReadOnly : File (Read p) -> File ReadOnly
asReadOnly (Internal.File filePath) =
    Internal.File filePath


asWriteOnly : File (Write p) -> File WriteOnly
asWriteOnly (Internal.File filePath) =
    Internal.File filePath


read : File (Read p) -> Internal.Script Error String
read (Internal.File filePath) =
    Internal.Invoke "readFile" (Path.encode filePath) <|
        \flags ->
            Decode.oneOf
                [ Decode.string |> Decode.map Internal.Succeed
                , errorDecoder |> Decode.map Internal.Fail
                ]


decodeNullResult : Flags -> Decoder (Internal.Script Error ())
decodeNullResult flags =
    Decode.oneOf
        [ Decode.null (Internal.Succeed ())
        , errorDecoder |> Decode.map Internal.Fail
        ]


write : String -> File (Write p) -> Internal.Script Error ()
write contents (Internal.File filePath) =
    Internal.Invoke "writeFile"
        (Encode.object
            [ ( "contents", Encode.string contents )
            , ( "path", Path.encode filePath )
            ]
        )
        decodeNullResult


writeTo : File (Write p) -> String -> Internal.Script Error ()
writeTo file contents =
    write contents file


copy : File (Read sourcePermissions) -> File (Write destinationPermissions) -> Internal.Script Error ()
copy (Internal.File sourcePath) (Internal.File destinationPath) =
    Internal.Invoke "copyFile"
        (Encode.object
            [ ( "sourcePath", Path.encode sourcePath )
            , ( "destinationPath", Path.encode destinationPath )
            ]
        )
        decodeNullResult


move : File Writable -> File (Write destinationPermissions) -> Internal.Script Error ()
move (Internal.File sourcePath) (Internal.File destinationPath) =
    Internal.Invoke "moveFile"
        (Encode.object
            [ ( "sourcePath", Path.encode sourcePath )
            , ( "destinationPath", Path.encode destinationPath )
            ]
        )
        decodeNullResult


delete : File (Write p) -> Internal.Script Error ()
delete (Internal.File filePath) =
    Internal.Invoke "deleteFile" (Path.encode filePath) decodeNullResult


copyInto : Directory (Write directoryPermissions) -> File (Read filePermissions) -> Internal.Script Error (File (Write directoryPermissions))
copyInto directory file =
    let
        destination =
            Directory.file (name file) directory
    in
    copy file destination |> Script.andThen (\() -> Script.succeed destination)


moveInto : Directory (Write directoryPermissions) -> File Writable -> Internal.Script Error (File (Write directoryPermissions))
moveInto directory file =
    let
        destination =
            Directory.file (name file) directory
    in
    move file destination |> Script.andThen (\() -> Script.succeed destination)


checkExistence : File (Read p) -> Internal.Script Error Existence
checkExistence (Internal.File filePath) =
    FileInfo.get filePath
        |> Script.map
            (\fileInfo ->
                case fileInfo of
                    FileInfo.File ->
                        Exists

                    FileInfo.Nonexistent ->
                        DoesNotExist

                    FileInfo.Directory ->
                        IsNotAFile

                    FileInfo.Other ->
                        IsNotAFile
            )
        |> Script.mapError Error


path : File p -> String
path (Internal.File filePath) =
    Path.toString filePath

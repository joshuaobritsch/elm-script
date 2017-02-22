port module Main exposing (..)

import Kintail.Script as Script exposing (Script)
import Time exposing (Time)
import Json.Encode exposing (Value)
import Json.Decode as Decode
import Http
import Task exposing (Task)


script : Script Int ()
script =
    Script.init { text = "A", number = 2 }
        |> Script.aside
            (\model ->
                Script.do
                    [ Script.print model.text
                    , printCurrentTime
                    , Script.sleep (0.5 * Time.second)
                    ]
            )
        |> Script.map .number
        |> Script.aside
            (\number ->
                Script.do
                    [ Script.print (toString number)
                    , printCurrentTime
                    , Script.sleep (0.5 * Time.second)
                    , getCurrentTime |> Script.ignore
                    ]
            )
        |> Script.andThen
            (\number ->
                if number > 2 then
                    Script.succeed ()
                else
                    Script.fail "Ugh, number is too small"
            )
        |> Script.onError handleError


getCurrentTime : Script String String
getCurrentTime =
    let
        url =
            "http://time.jsontest.com/"

        decoder =
            Decode.field "time" Decode.string
    in
        Script.request (Http.get url decoder)
            |> Script.mapError (always "HTTP request failed")


printCurrentTime : Script String ()
printCurrentTime =
    getCurrentTime |> Script.andThen Script.print


handleError : String -> Script Int ()
handleError message =
    Script.print ("ERROR: " ++ message)
        |> Script.andThen (\() -> Script.fail 1)


port requestPort : Value -> Cmd msg


port responsePort : (Value -> msg) -> Sub msg


main =
    Script.run script requestPort responsePort
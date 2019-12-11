module Script exposing
    ( Script, Context
    , RequestPort, ResponsePort, Program, program
    , succeed, fail
    , printLine, sleep, getCurrentTime
    , map, map2, map3, map4, ignore
    , do, forEach, sequence, collect, andThen, aside
    , Arguments, with, andWith, yield, return
    , mapError, attempt, onError, ignoreError, finally
    , Shell, SubprocessError(..)
    )

{-| The functions in this module let you define scripts, chain them together in
various ways, and turn them into runnable programs.

@docs Script, Context


# Running

@docs RequestPort, ResponsePort, Program, program


# Basics

@docs succeed, fail


# Utilities

@docs printLine, sleep, getCurrentTime


# Mapping

@docs map, map2, map3, map4, ignore


# Sequencing

@docs do, forEach, sequence, collect, andThen, aside


# Combining

@docs Arguments, with, andWith, yield, return


# Error handling

@docs mapError, attempt, onError, ignoreError, finally


# Running subprocesses

@docs Shell, SubprocessError

-}

import Dict exposing (Dict)
import Duration exposing (Duration)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Platform.Cmd as Cmd
import Process
import Script.EnvironmentVariables exposing (EnvironmentVariables)
import Script.Internal as Internal
import Script.NetworkConnection exposing (NetworkConnection)
import Script.Path as Path
import Script.Permissions exposing (ReadOnly, Writable, WriteOnly)
import Task exposing (Task)
import Time


requiredHostVersion : ( Int, Int )
requiredHostVersion =
    ( 5, 0 )


{-| A `Script x a` value defines a script that, when run, will either produce a
value of type `a` or an error of type `x`.
-}
type alias Script x a =
    Internal.Script x a


{-| The context in which a `Script` is running. The function you pass to
`Script.program` will get a `Context` value passed to it at startup.
-}
type alias Context =
    { arguments : List String
    , environmentVariables : EnvironmentVariables
    , fileSystem : FileSystem
    , workingDirectory : Internal.Directory Writable
    , networkConnection : NetworkConnection
    , shell : Shell
    , platform : Platform
    }


type alias Flags =
    { arguments : List String
    , platform : String
    , environmentVariables : List ( String, String )
    }


type alias FileSystem =
    { readOnlyFile : String -> Internal.File ReadOnly
    , writableFile : String -> Internal.File Writable
    , writeOnlyFile : String -> Internal.File WriteOnly
    , readOnlyDirectory : String -> Internal.Directory ReadOnly
    , writableDirectory : String -> Internal.Directory Writable
    , writeOnlyDirectory : String -> Internal.Directory WriteOnly
    }


type alias Shell =
    { execute : String -> List String -> Script SubprocessError String
    , executeIn : Internal.Directory Writable -> String -> List String -> Script SubprocessError String
    }


type SubprocessError
    = ExecutableNotFound
    | SubprocessFailed String
    | SubprocessWasTerminated
    | SubprocessExitedWithError Int


type alias Platform =
    { pathSeparator : String
    , lineSeparator : String
    }


{-| The type of port that scripts use to send requests to the external runner.
You will need to declare a compatible port named `requestPort` in your top-level
Elm file, like so:

    port requestPort : Value -> Cmd msg

(Note the lower-case `msg` since this is the format Elm requires for ports.)

-}
type alias RequestPort =
    Value -> Cmd Msg


{-| The type of port that scripts use to receive responses from the external
runner. You will need to declare a compatible port named `responsePort` in your
top-level Elm file, like so:

    port responsePort : (Value -> msg) -> Sub msg

(Note the lower-case `msg` since this is the format Elm requires for ports.)

-}
type alias ResponsePort =
    (Value -> Msg) -> Sub Msg


type Model
    = Model (Script Int ())


type Msg
    = Updated (Script Int ())
    | Response Value


{-| The type of program returned by `Script.program`.
-}
type alias Program =
    Platform.Program Flags Model Msg


{-| Actually create a runnable script program! Your top-level script file should
have `main` defined as

    main : Script.Program
    main =
        Script.program script requestPort responsePort

The function provided as the first argument to `Script.program` must accept a
`Context` value and produce a `Script Int ()`. If this script succeeds with
`()`, then a value of 0 will be returned to the operating system as the return
value of the script. If the script fails with an `Int` value, then that value
will be returned to the operating system instead.

-}
program : (Context -> Script Int ()) -> RequestPort -> ResponsePort -> Program
program main requestPort responsePort =
    let
        checkHostVersion =
            let
                ( major, minor ) =
                    requiredHostVersion

                encodedVersion =
                    Encode.list Encode.int [ major, minor ]

                decoder =
                    Decode.null (succeed ())
            in
            Internal.Invoke "checkVersion" encodedVersion decoder

        init flags =
            let
                platform =
                    if flags.platform == "windows" then
                        Internal.Windows

                    else
                        Internal.Posix

                environmentVariables =
                    Internal.EnvironmentVariables platform
                        (Dict.fromList <|
                            -- On Windows, capitalize environment variable names
                            -- so they can be looked up case-insensitively (same
                            -- behavior as process.env in Node)
                            case platform of
                                Internal.Posix ->
                                    flags.environmentVariables

                                Internal.Windows ->
                                    List.map (Tuple.mapFirst String.toUpper)
                                        flags.environmentVariables
                        )

                workingDirectory =
                    Internal.Directory [ "." ]

                context =
                    { arguments = flags.arguments
                    , environmentVariables = environmentVariables
                    , platform =
                        case platform of
                            Internal.Windows ->
                                { pathSeparator = "\\"
                                , lineSeparator = "\u{000D}\n"
                                }

                            Internal.Posix ->
                                { pathSeparator = "/"
                                , lineSeparator = "\n"
                                }
                    , fileSystem =
                        { readOnlyFile = \path -> Internal.File [ path ]
                        , writableFile = \path -> Internal.File [ path ]
                        , writeOnlyFile = \path -> Internal.File [ path ]
                        , readOnlyDirectory = \path -> Internal.Directory [ path ]
                        , writableDirectory = \path -> Internal.Directory [ path ]
                        , writeOnlyDirectory = \path -> Internal.Directory [ path ]
                        }
                    , workingDirectory = workingDirectory
                    , networkConnection = Internal.NetworkConnection
                    , shell =
                        { executeIn = executeIn
                        , execute = executeIn workingDirectory
                        }
                    }

                script =
                    checkHostVersion |> andThen (\() -> main context)
            in
            ( Model script, commands script )

        submitRequest name value =
            requestPort <|
                Encode.object
                    [ ( "name", Encode.string name )
                    , ( "value", value )
                    ]

        commands script =
            case script of
                Internal.Succeed () ->
                    submitRequest "exit" (Encode.int 0)

                Internal.Fail errorCode ->
                    submitRequest "exit" (Encode.int errorCode)

                Internal.Perform task ->
                    Task.perform Updated task

                Internal.Invoke name value _ ->
                    submitRequest name value

                Internal.Do command ->
                    Cmd.map Updated command

        crash message =
            let
                printError =
                    printLine ("ERROR: " ++ message) |> andThen (\() -> fail 1)
            in
            ( Model printError, commands printError )

        update message (Model current) =
            case message of
                Updated updated ->
                    ( Model updated, commands updated )

                Response value ->
                    case current of
                        Internal.Invoke _ _ decoder ->
                            case Decode.decodeValue decoder value of
                                Ok updated ->
                                    ( Model updated, commands updated )

                                Err decodeError ->
                                    crash ("Failed to decode response from JavaScript: " ++ Decode.errorToString decodeError)

                        _ ->
                            crash ("Received unexpected response from JavaScript: " ++ Encode.encode 0 value)
    in
    Platform.worker
        { init = init
        , update = update
        , subscriptions = always (responsePort Response)
        }


{-| A script that succeeds immediately with the given value.
-}
succeed : a -> Script x a
succeed =
    Internal.Succeed


{-| A script that fails immediately with the given value. The following script
greets someone by their name given by the first command-line argument, or prints
an error message and then returns an error code if no names or multiple names
are given:

    script : List String -> Script Int ()
    script args =
        case args of
            [ name ] ->
                Script.printLine ("Hello " ++ name ++ "!")

            [] ->
                Script.printLine "Please enter a name"
                    |> Script.andThen (\() -> Script.fail 1)

            _ ->
                Script.printLine "Please enter only one name!"
                    |> Script.andThen (\() -> Script.fail 2)

-}
fail : x -> Script x a
fail =
    Internal.Fail


{-| Print a line to the console. A newline will be added to the given string if
it does not already have one, so all of the following are equivalent:

    Script.do
        [ Script.printLine "Hello"
        , Script.printLine "World"
        ]

    Script.do
        [ Script.printLine "Hello\n"
        , Script.printLine "World\n"
        ]

    Script.printLine "Hello\nWorld"

    Script.printLine "Hello\nWorld\n"

-}
printLine : String -> Script x ()
printLine string =
    let
        stringWithNewline =
            if String.endsWith "\n" string then
                string

            else
                string ++ "\n"
    in
    Internal.Invoke "writeStdout"
        (Encode.string stringWithNewline)
        (Decode.null (succeed ()))


{-| Sleep (pause) for the given number of milliseconds.

    -- Sleep for 5 seconds
    Script.sleep (Duration.milliseconds 5000)

-}
sleep : Duration -> Script x ()
sleep duration =
    Internal.Perform <|
        Task.map succeed (Process.sleep (Duration.inMilliseconds duration))


{-| Get the current time.

    Script.getCurrentTime
        |> Script.andThen
            (\currentTime ->
                Script.printLine <|
                    "Number of hours since January 1, 1970: "
                        ++ toString (Time.inHours currentTime)
            )

-}
getCurrentTime : Script x Time.Posix
getCurrentTime =
    Internal.perform Time.now


{-| Map the value produced by a script; to get a list of lines from a file
instead of the entire contents as a single string, you might do

    getLines : Script File.Error (List String)
    getLines =
        File.read inputFile |> Script.map String.lines

-}
map : (a -> b) -> Script x a -> Script x b
map function script =
    script |> andThen (\value -> succeed (function value))


{-| Map over the values produced by two scripts. The two scripts will be run in
sequence.
-}
map2 :
    (a -> b -> c)
    -> Script x a
    -> Script x b
    -> Script x c
map2 function scriptA scriptB =
    scriptA |> andThen (\valueA -> map (function valueA) scriptB)


{-| Map over the values produced by three scripts. The three scripts will be run
in sequence.
-}
map3 :
    (a -> b -> c -> d)
    -> Script x a
    -> Script x b
    -> Script x c
    -> Script x d
map3 function scriptA scriptB scriptC =
    scriptA |> andThen (\valueA -> map2 (function valueA) scriptB scriptC)


{-| Map over the values produced by four scripts. The four scripts will be run
in sequence.
-}
map4 :
    (a -> b -> c -> d -> e)
    -> Script x a
    -> Script x b
    -> Script x c
    -> Script x d
    -> Script x e
map4 function scriptA scriptB scriptC scriptD =
    scriptA |> andThen (\valueA -> map3 (function valueA) scriptB scriptC scriptD)


{-| Explicitly ignore the value produced by a script. This is sometimes useful
when using a function like `Script.do` that expects all of its arguments to have
the type `Script x ()` (a script that produces no meaningful output):

    Script.do
        [ Script.printLine "Reading file..."
        , Script.readFile inputFile |> Script.ignore
        , Script.printLine "Read file!"
        ]

(Why would you want to read a file without doing anything with the output,
though?)

-}
ignore : Script x a -> Script x ()
ignore =
    map (always ())


{-| Execute a list of scripts in sequence. `Script.do` expects each given script
to have a return type of `()` (no meaningful output), and so itself has a return
type of `()`.

    Script.do
        [ Script.printLine "Reading a file..."
        , File.read inputFile
            |> Script.map String.lines
            |> Script.andThen
                (\lines ->
                    Script.printLine <|
                        toString (List.length lines)
                            ++ " lines"
                )
        ]

If you need to execute a list of scripts but collect their return values, use
`Script.sequence` instead.

-}
do : List (Script x ()) -> Script x ()
do scripts =
    case scripts of
        [] ->
            succeed ()

        first :: rest ->
            first |> andThen (\() -> do rest)


{-| For every value in a given list, call the given function and run the
script that it creates. From `examples/ForEach.elm`:

    script : Script.Context -> Script Int ()
    script { arguments } =
        arguments
            |> Script.forEach
                (\argument ->
                    Script.printLine <|
                        case String.toFloat argument of
                            Ok value ->
                                let
                                    squared =
                                        value * value
                                in
                                argument ++ " squared is " ++ toString squared

                            Err _ ->
                                argument ++ " is not a number!"
                )

Often works well with `Script.andThen` if the previous script produces a list of
values:

    Directory.listFiles directory
        |> Script.andThen
            (Script.forEach
                (\file ->
                    Script.printLine (File.name file)
                )
            )

-}
forEach : (a -> Script x ()) -> List a -> Script x ()
forEach function values =
    do (List.map function values)


{-| Run a list of scripts in sequence and collect their results into a list.
-}
sequence : List (Script x a) -> Script x (List a)
sequence scripts =
    case scripts of
        [] ->
            succeed []

        first :: rest ->
            first |> andThen (\value -> sequence rest |> map ((::) value))


{-| For every value in a given list, call the given function and run the script
that it creates, then collect the results of all those scripts into a list.

    readAll : Script File.Error (List String)
    readAll =
        Script.collect File.read
            [ file1, file2, file3 ]

-}
collect : (a -> Script x b) -> List a -> Script x (List b)
collect function values =
    sequence (List.map function values)


{-| Take the output from one script and feed it into a second script:

    File.read inputFile
        |> Script.andThen
            (\fileContents ->
                Script.printLine contents
            )

This is the most fundamental way to chain scripts together! Pretty much all
other combinators in this module (`forEach`, `do`, `map` etc.) can be
implemented in terms of `andThen`, so if there's some custom behavior you need
that is not covered by one of those functions you should be able to implement it
using `andThen`.

-}
andThen : (a -> Script x b) -> Script x a -> Script x b
andThen function script =
    case script of
        Internal.Succeed value ->
            function value

        Internal.Fail error ->
            fail error

        Internal.Perform task ->
            Internal.Perform (Task.map (andThen function) task)

        Internal.Invoke name value decoder ->
            Internal.Invoke name value (Decode.map (andThen function) decoder)

        Internal.Do command ->
            Internal.Do (Cmd.map (andThen function) command)


{-| Sometimes you can run into problems chaining scripts together using
`andThen` if you want to do 'auxiliary' things like print to the console, log to
a file etc. For example, the following will **not** work:

    File.read inputFile
        |> Script.andThen
            (\contents -> Script.print "OK, read file")
        |> Script.andThen
            (\contents -> ...)

`File.read inputFile` succeeds with a `String` which is passed into the first
`andThen`, but since `Script.print` succeeds with just the unit value `()` that
is what gets passed into the second `andThen`!

You can use `aside` for this purpose, which lets you run a script on some
produced value but then 'pass it through' to the next script:

    File.read inputFile
        |> Script.aside
            (\contents -> Script.print "OK, read file")
        |> Script.andThen
            (\contents ->
                ...
            )

This is safe because `aside` enforces that the first script produces `()` - that
is, it doesn't actually produce any useful output that you might want anway.

-}
aside : (a -> Script x ()) -> Script x a -> Script x a
aside doSomething script =
    -- Run the given script...
    script
        |> andThen
            (\value ->
                -- ...as an 'aside' do something with the generated value
                -- (logging, printing to console etc)...
                doSomething value
                    |> andThen
                        -- ...finally, succeed with the original generated value
                        -- (not the unit return value of the 'aside' script)
                        (\() -> succeed value)
            )


type Arguments f r
    = Arguments (f -> r)


with : Script x a -> Script x (Arguments (a -> r) r)
with =
    map (\value -> Arguments (\function -> function value))


andWith : Script x b -> Script x (Arguments f (b -> r)) -> Script x (Arguments f r)
andWith scriptB argumentsScriptA =
    map2
        (\(Arguments callerA) valueB ->
            Arguments (\valueA -> callerA valueA valueB)
        )
        argumentsScriptA
        scriptB


yield : f -> Script x (Arguments f (Script x r)) -> Script x r
yield function =
    andThen (\(Arguments caller) -> caller function)


return : f -> Script x (Arguments f r) -> Script x r
return function =
    map (\(Arguments caller) -> caller function)


mapError : (x -> y) -> Script x a -> Script y a
mapError function =
    onError (function >> fail)


attempt : Script x a -> Script y (Result x a)
attempt =
    map Ok >> onError (Err >> succeed)


onError : (x -> Script y a) -> Script x a -> Script y a
onError recover script =
    case script of
        Internal.Succeed value ->
            succeed value

        Internal.Fail error ->
            recover error

        Internal.Perform task ->
            Internal.Perform (Task.map (onError recover) task)

        Internal.Invoke name value decoder ->
            Internal.Invoke name value (Decode.map (onError recover) decoder)

        Internal.Do command ->
            Internal.Do (Cmd.map (onError recover) command)


ignoreError : Script x () -> Script y ()
ignoreError =
    onError (always (succeed ()))


finally : Script Never () -> Script x a -> Script x a
finally cleanup script =
    script
        |> andThen (\result -> cleanup |> onError never |> andThen (\() -> succeed result))
        |> onError (\error -> cleanup |> onError never |> andThen (\() -> fail error))



----- SUBPROCESS EXECUTION


executeIn : Internal.Directory Writable -> String -> List String -> Internal.Script SubprocessError String
executeIn workingDirectory command arguments =
    let
        (Internal.Directory workingPath) =
            workingDirectory
    in
    Internal.Invoke "execute"
        (Encode.object
            [ ( "command", Encode.string command )
            , ( "arguments", Encode.list Encode.string arguments )
            , ( "workingDirectory", Path.encode workingPath )
            ]
        )
        (Decode.oneOf
            [ Decode.string |> Decode.map Internal.Succeed
            , Decode.field "error" Decode.string
                |> Decode.andThen
                    (\error ->
                        case error of
                            "notfound" ->
                                Decode.succeed ExecutableNotFound

                            "failed" ->
                                Decode.field "message" Decode.string
                                    |> Decode.map SubprocessFailed

                            "terminated" ->
                                Decode.succeed SubprocessWasTerminated

                            "exited" ->
                                Decode.field "code" Decode.int
                                    |> Decode.map SubprocessExitedWithError

                            _ ->
                                Decode.fail "Unexpected execution error type"
                    )
                |> Decode.map Internal.Fail
            ]
        )

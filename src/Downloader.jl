module Downloader

export add_download, download

using LibCURL

mutable struct Curl
    multi::Ptr{Cvoid}
    timer::Ptr{Cvoid}
    roots::IdDict{Ptr{Cvoid},IO}
end

include("helpers.jl")
include("callbacks.jl")

## setup & teardown ##

function Curl()
    uv_timer_size = Base._sizeof_uv_timer
    timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), uv_timer_size)
    uv_timer_init(timer)

    @check curl_global_init(CURL_GLOBAL_ALL)
    multi = curl_multi_init()

    # create object & set finalizer
    curl = Curl(multi, timer, IdDict{Ptr{Cvoid},IO}())
    finalizer(curl) do curl
        uv_close(curl.timer, cglobal(:jl_free))
        curl_multi_cleanup(curl.multi)
    end
    curl_p = pointer_from_objref(curl)

    # stash curl pointer in timer
    ## TODO: use a member access API
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, timer), curl_p)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(multi, CURLMOPT_TIMERDATA, curl_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, curl_p)

    return curl
end

## API ##

function add_download(curl::Curl, url::AbstractString, io::IO)
    # init a single curl handle
    easy = curl_easy_init()

    # HTTP options
    @check curl_easy_setopt(easy, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)

    # HTTPS: tell curl where to find certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(easy, CURLOPT_CAINFO, certs_file)

    # set the URL and request to follow redirects
    @check curl_easy_setopt(easy, CURLOPT_URL, url)
    @check curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, true)

    # associate IO object with handle
    curl.roots[easy] = io
    io_p = pointer_from_objref(io)
    @check curl_easy_setopt(easy, CURLOPT_WRITEDATA, io_p)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)

    # add curl handle to be multiplexed
    @check curl_multi_add_handle(curl.multi, easy)

    return easy
end

function download(url::AbstractString)
    io = IOBuffer()
    add_download(Curl(), url, io)
    sleep(1)
    return String(take!(io))
end

end # module

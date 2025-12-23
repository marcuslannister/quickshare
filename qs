#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# Copyright 2013 Cédric Picard
#
# LICENSE
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
# END_OF_LICENSE
#


"""
Quickly share directories using a simple http server.

Usage: qs [-h] [-p PORT] [-r RATE] [--no-sf] [FILE]...

Options:
    -h, --help          Print this help and exit.
    -p, --port PORT     Port on which the server is listening.
                        Default is 8000
    -r, --rate RATE     Limit upload to RATE in ko/s.
                        Default is 0 meaning no limitation.
    --no-sf             Do not search a free port if the selected one is taken.
                        Otherwise, increase the port number until it finds one.
    --version           Print the current version

Arguments:
    FILE                Files or directory to share.
                        Default is the current directory: `.'
                        If '-' is given, read from stdin.
                        If 'index.html' is found in the directory, it is served.
"""

VERSION = "1.4.2"


import os
import sys
import time
import socket
import errno
import tempfile
from docopt    import docopt
from threading import Lock

# Manage python3 compatibility
if sys.version_info[0] == 3:
    import http.server      as SimpleHTTPServer
    import socketserver     as SocketServer
else:
    import SimpleHTTPServer
    import SocketServer


class TokenBucket:
    """
    An implementation of the token bucket algorithm. See also :
    http://code.activestate.com/recipes/578659-python-3-token-bucket-rate-limit/
    """
    def __init__(self):
        self.tokens = 0
        self.rate = 0
        self.last = time.time()
        self.lock = Lock()

    def set_rate(self, rate):
        with self.lock:
            self.rate = rate
            self.tokens = self.rate

    def consume(self, tokens):
        with self.lock:
            if not self.rate:
                return 0

            now = time.time()
            lapse = now - self.last
            self.last = now
            self.tokens += lapse * self.rate

            if self.tokens > self.rate:
                self.tokens = self.rate

            self.tokens -= tokens

            if self.tokens >= 0:
                return 0
            else:
                return -self.tokens / self.rate


class HTTPRequestHandler(SimpleHTTPServer.SimpleHTTPRequestHandler):
    """
    SimpleHTTPRequestHandler with overiden methods to include rate limit.
    """

    def __init__(self, request, client_address, server, rate, path):
        self._range         = None
        self.rate           = rate * 1024
        self.bucket         = TokenBucket()
        self.bucket.set_rate(self.rate)
        if sys.version_info[0] == 3:
            try:
                SimpleHTTPServer.SimpleHTTPRequestHandler.__init__(self,
                                                                  request,
                                                                  client_address,
                                                                  server,
                                                                  directory=path)
            except TypeError:
                SimpleHTTPServer.SimpleHTTPRequestHandler.__init__(self,
                                                                  request,
                                                                  client_address,
                                                              server)
            self.directory = path
        else:
            SimpleHTTPServer.SimpleHTTPRequestHandler.__init__(self,
                                                              request,
                                                              client_address,
                                                              server)
            self.directory = path

    def _send_range_not_satisfiable(self, file_size):
        self.send_response(416)
        self.send_header("Content-Range", "bytes */%d" % file_size)
        self.end_headers()
        return None

    def _parse_range_header(self, header, file_size):
        if not header.startswith("bytes="):
            return (None, None)

        range_spec = header[len("bytes="):].strip()
        if not range_spec or "," in range_spec:
            return (None, None)

        if "-" not in range_spec:
            return (None, None)

        start_str, end_str = range_spec.split("-", 1)
        if file_size <= 0:
            return (None, None)

        if start_str == "":
            try:
                suffix_len = int(end_str)
            except ValueError:
                return (None, None)
            if suffix_len <= 0:
                return (None, None)
            if suffix_len > file_size:
                suffix_len = file_size
            return (file_size - suffix_len, file_size - 1)

        try:
            start = int(start_str)
        except ValueError:
            return (None, None)
        if start < 0:
            return (None, None)

        if end_str == "":
            end = file_size - 1
        else:
            try:
                end = int(end_str)
            except ValueError:
                return (None, None)
            if end < 0:
                return (None, None)

        if start >= file_size or end < start:
            return (None, None)
        if end >= file_size:
            end = file_size - 1

        return (start, end)

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            if not self.path.endswith('/'):
                self.send_response(301)
                self.send_header("Location", self.path + "/")
                self.end_headers()
                return None
            for index in ("index.html", "index.htm"):
                index = os.path.join(path, index)
                if os.path.exists(index):
                    path = index
                    break
            else:
                return self.list_directory(path)

        ctype = self.guess_type(path)
        try:
            f = open(path, 'rb')
        except IOError:
            self.send_error(404, "File not found")
            return None

        fs = os.fstat(f.fileno())
        file_size = fs[6]

        range_header = self.headers.get("Range")
        if range_header:
            start, end = self._parse_range_header(range_header, file_size)
            if start is None:
                f.close()
                return self._send_range_not_satisfiable(file_size)

            self._range = (start, end)
            self.send_response(206)
            self.send_header("Content-type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range",
                             "bytes %d-%d/%d" % (start, end, file_size))
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Last-Modified", self.date_time_string(fs.st_mtime))
            self.end_headers()
            return f

        self._range = None
        self.send_response(200)
        self.send_header("Content-type", ctype)
        self.send_header("Content-Length", str(file_size))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Last-Modified", self.date_time_string(fs.st_mtime))
        self.end_headers()
        return f

    def copyfile(self, source, outputfile):
        if self._range:
            start, end = self._range
            source.seek(start)
            self.copyfileobj(source,
                             outputfile,
                             remaining=(end - start + 1))
        else:
            self.copyfileobj(source, outputfile)

    def copyfileobj(self, fsrc, fdst, length=16*1024, remaining=None):
        """
        copy data from file-like object fsrc to file-like object fdst
        overidden to include token bucket rate limiting
        """
        completed = False
        while 1:
            if remaining is not None and remaining <= 0:
                completed = True
                break
            read_len = length
            if remaining is not None:
                read_len = min(length, remaining)
            if self.rate != 0:
                time.sleep(self.bucket.consume(read_len))
            buf = fsrc.read(read_len)
            if not buf:
                completed = True
                break
            try:
                fdst.write(buf)
            except (OSError, IOError) as exc:
                err_no = getattr(exc, "errno", None)
                if err_no in (errno.EPIPE, errno.ECONNRESET, errno.ECONNABORTED):
                    break
                raise
            if remaining is not None:
                remaining -= len(buf)
        if completed:
            print(" - - [%s] SENT -" % time.strftime("%d/%b/%Y %H:%M:%S"))


class _TCPServer(SocketServer.TCPServer):
    def __init__(self,
                 server_address,
                 RequestHandlerClass,
                 rate,
                 path,
                 bind_and_activate=True):
        self.rate = rate
        self.path = path
        SocketServer.TCPServer.__init__(self,
                                        server_address,
                                        RequestHandlerClass,
                                        bind_and_activate)

    def finish_request(self, request, client_address):
        self.RequestHandlerClass(request,
                                 client_address,
                                 self,
                                 self.rate,
                                 self.path)


def share(share_queue, port, rate, search_free):
    filename=""

    if len(share_queue) == 1 and os.path.isdir(share_queue[0]):
        path = share_queue[0]
        delete_at_end = False

    else:
        path = tempfile.mkdtemp(prefix='qstmp_')
        delete_at_end = True
        for each in share_queue:
            os.symlink(each, os.path.join(path, os.path.basename(each)))

        if len(share_queue) == 1:
            filename = os.path.basename(share_queue[0])

    os.chdir(path)

    try:
        httpd = _TCPServer(("", port), HTTPRequestHandler, rate, path)

    except SocketServer.socket.error:
        print("Port already in use: " + str(port))

        if search_free:
            print("Trying on port " + str(port + 1))
            share(share_queue, port + 1, rate, search_free)
        else:
            exit(1)

    else:
        print("Serving at port " + str(port))
        print("Local url: http://%s:%s/%s" % (get_ip(), port, filename))
        httpd.serve_forever()

    finally:
        if delete_at_end and 'qstmp_' in path:
            for each in [os.path.join(path, x) for x in os.listdir(path)]:
                os.remove(each)
            os.removedirs(path)


def get_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # doesn't even have to be reachable
        s.connect(('10.255.255.255', 0))
        IP = s.getsockname()[0]
    except:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP


def main():
    args = docopt(__doc__, version=VERSION)
    share_queue = args['FILE']        or '.'
    port        = args['--port']      or 8000
    rate        = args['--rate']      or 0
    search_free = not args['--no-sf']

    port = int(port)
    rate = int(rate)

    if share_queue == ['-']:
        share_queue = [x.rstrip('\n') for x in sys.stdin.readlines()]

    try:
        share_queue = [os.path.abspath(x) for x in share_queue]
        share(share_queue, port, rate, search_free)
    except KeyboardInterrupt:
        print("")
        exit(0)

if __name__ == "__main__":
    main()

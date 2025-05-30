# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

import fnmatch
import gzip
import os
from pathlib import Path

import click

from .command import Bash, Command, default_bin
from ..compat import _get_module
from .git import git
from .logger import logger
from ..lang.python import NumpyDoc
from .tmpdir import tmpdir


_archery_install_msg = (
    "Please install archery using: `pip install -e dev/archery[lint]`. "
)


class LintValidationException(Exception):
    pass


class LintResult:
    def __init__(self, success, reason=None):
        self.success = success

    def ok(self):
        if not self.success:
            raise LintValidationException

    @staticmethod
    def from_cmd(command_result):
        return LintResult(command_result.returncode == 0)


def python_numpydoc(symbols=None, allow_rules=None, disallow_rules=None):
    """Run numpydoc linter on python.

    Pyarrow must be available for import.
    """
    logger.info("Running Python docstring linters")
    # by default try to run on all pyarrow package
    symbols = symbols or {
        'pyarrow',
        'pyarrow.compute',
        'pyarrow.csv',
        'pyarrow.dataset',
        'pyarrow.feather',
        # 'pyarrow.flight',
        'pyarrow.fs',
        'pyarrow.gandiva',
        'pyarrow.ipc',
        'pyarrow.json',
        'pyarrow.orc',
        'pyarrow.parquet',
        'pyarrow.types',
    }
    try:
        numpydoc = NumpyDoc(symbols)
    except RuntimeError as e:
        logger.error(str(e))
        yield LintResult(success=False)
        return

    results = numpydoc.validate(
        # limit the validation scope to the pyarrow package
        from_package='pyarrow',
        allow_rules=allow_rules,
        disallow_rules=disallow_rules
    )

    if len(results) == 0:
        yield LintResult(success=True)
        return

    number_of_violations = 0
    for obj, result in results:
        errors = result['errors']

        # inspect doesn't play nice with cython generated source code,
        # to use a hacky way to represent a proper __qualname__
        doc = getattr(obj, '__doc__', '')
        name = getattr(obj, '__name__', '')
        qualname = getattr(obj, '__qualname__', '')
        module = _get_module(obj, default='')
        instance = getattr(obj, '__self__', '')
        if instance:
            klass = instance.__class__.__name__
        else:
            klass = ''

        try:
            cython_signature = doc.splitlines()[0]
        except Exception:
            cython_signature = ''

        desc = '.'.join(filter(None, [module, klass, qualname or name]))

        click.echo()
        click.echo(click.style(desc, bold=True, fg='yellow'))
        if cython_signature:
            qualname_with_signature = '.'.join([module, cython_signature])
            click.echo(
                click.style(
                    f'-> {qualname_with_signature}',
                    fg='yellow'
                )
            )

        for error in errors:
            number_of_violations += 1
            click.echo(f'{error[0]}: {error[1]}')

    msg = f'Total number of docstring violations: {number_of_violations}'
    click.echo()
    click.echo(click.style(msg, fg='red'))

    yield LintResult(success=False)


def linter(src, fix=False, path=None, *, clang_format=False, cpplint=False,
           clang_tidy=False, iwyu=False, iwyu_all=False,
           python=False, numpydoc=False, cmake_format=False, rat=False,
           r=False, docker=False, docs=False):
    """Run all linters."""
    with tmpdir(prefix="arrow-lint-") as root:
        build_dir = os.path.join(root, "cpp-build")

        # Linters yield LintResult without raising exceptions on failure.
        # This allows running all linters in one pass and exposing all
        # errors to the user.
        results = []

        if clang_format or cpplint or clang_tidy or iwyu:
            results.extend(cpp_linter(src, build_dir,
                                      clang_format=clang_format,
                                      cpplint=cpplint,
                                      clang_tidy=clang_tidy,
                                      iwyu=iwyu,
                                      iwyu_all=iwyu_all,
                                      fix=fix))

        if python:
            results.extend(python_linter(src, fix=fix))

        if python and clang_format:
            results.extend(python_cpp_linter(src,
                                             clang_format=clang_format,
                                             fix=fix))

        if numpydoc:
            results.extend(python_numpydoc())

        if cmake_format:
            results.extend(cmake_linter(src, fix=fix))

        if rat:
            results.extend(rat_linter(src, root))

        if r:
            results.extend(r_linter(src))

        if docker:
            results.extend(docker_linter(src))

        if docs:
            results.extend(docs_linter(src, path))

        # Raise error if one linter failed, ensuring calling code can exit with
        # non-zero.
        for result in results:
            result.ok()

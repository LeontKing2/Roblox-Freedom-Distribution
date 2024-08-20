from re import S
from typing import ParamSpec, TypeVar, Generic
import enum


class call_mode_enum(enum.Enum):
    assume = 'assume'
    lua = 'lua'
    python = 'python'
    dicted = 'dict'


R = TypeVar("R")
P = ParamSpec("P")


class obj_type(Generic[P, R]):
    def __init__(
        self,
        rep,
        call_mode: call_mode_enum,
        path: str, config,
        caster_func,
    ) -> None:
        self.rep = rep
        self.config = config
        self.field_path = path
        self.caster_func = caster_func
        self.call_mode = (
            self.assume_call_mode()
            if call_mode == call_mode_enum.assume else
            call_mode
        )
        self._call = self.get_call()

    def __call__(self, *args: P.args, **kwargs: P.kwargs) -> R:
        result = self._call(*args, *kwargs.values())
        return self.caster_func(result)

    def assume_call_mode(self) -> call_mode_enum:
        rep = self.rep
        if isinstance(rep, str):
            checked = rep.strip()
            if checked.startswith('function'):
                return call_mode_enum.lua
            elif checked.startswith('def'):
                return call_mode_enum.python
            return call_mode_enum.lua
        if isinstance(rep, dict):
            return call_mode_enum.dicted
        raise Exception(
            "Config option at path `%s` isn't valid." %
            (self.field_path),
        )

    def get_call(self):
        match self.call_mode:
            case call_mode_enum.lua:
                def call(*args):
                    return self.config.data_transferer.call(
                        self.field_path, self.config, *args,
                    )
                return call
            case call_mode_enum.python:
                assert isinstance(self.rep, str)
                local_vars = {}
                exec(
                    self.rep,  # source
                    {},  # globals
                    local_vars,  # locals
                )
                return next(
                    v
                    for v in reversed(local_vars.values())
                    if callable(v)
                )
            case call_mode_enum.dicted:
                def call(*args):
                    assert isinstance(self.rep, dict)
                    arg_strs = [str(a) for a in args]
                    candidate_keys = [
                        *arg_strs,
                        '-'.join(arg_strs),
                        '_'.join(arg_strs),
                        ','.join(arg_strs),
                        ', '.join(arg_strs),
                        'default',
                    ]
                    return next(
                        (
                            self.rep[a]
                            for a in candidate_keys
                            if a in self.rep
                        ),
                        None,
                    )
                return call
            case _:
                raise Exception(
                    "Config option `%s` doesn't seem to be in a valid format." %
                    (self.field_path),
                )

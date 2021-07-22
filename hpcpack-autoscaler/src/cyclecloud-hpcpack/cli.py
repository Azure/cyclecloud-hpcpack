import json
import os
import sys
from argparse import ArgumentParser
from shutil import which
from subprocess import check_output
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .autoscaler import autoscale_hpcpack

from hpc.autoscale import clilib
from hpc.autoscale.job.demandcalculator import DemandCalculator
from hpc.autoscale.job.demandprinter import OutputFormat
from hpc.autoscale.job.driver import SchedulerDriver
from hpc.autoscale.job.job import Job
from hpc.autoscale import hpclogging as logging
from hpc.autoscale.node.nodemanager import new_node_manager
from hpc.autoscale.node.node import Node
from hpc.autoscale.job.schedulernode import SchedulerNode
from hpc.autoscale.results import (
    DefaultContextHandler,
    register_result_handler,
)


# TODO : Extract other CLI commands from autoscaler.py into driver

class HpcPackDriver(SchedulerDriver):
    def __init__(self, config: Dict) -> None:
        super().__init__("hpcpack")


    @property
    def autoscale_home(self) -> str:
        if os.getenv("AUTOSCALE_HOME"):
            return os.environ["AUTOSCALE_HOME"]
        return "C:\\cycle\\jetpack\\config"

    def initialize(self) -> None:
        pass

    def preprocess_config(self, config: Dict) -> Dict:
        return config

    def add_nodes_to_cluster(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def handle_boot_timeout(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def handle_draining(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def handle_failed_nodes(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def handle_post_delete(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def handle_post_join_cluster(self, nodes: List[Node]) -> List[Node]:
        return nodes

    def _read_jobs_and_nodes(
        self, config: Dict
    ) -> Tuple[List[Job], List[SchedulerNode]]:
        return ([], [])



class HpcPackCLI(clilib.CommonCLI):
    def __init__(self) -> None:
        clilib.CommonCLI.__init__(self, "hpcpack")
        self.__driver: Optional[HpcPackDriver] = None

    def connect(self, config: Dict) -> None:
        """Tests connection to CycleCloud"""    
        self._node_mgr(config)

    def _initialize(self, command: str, config: Dict) -> None:
        return

    def _driver(self, config: Dict) -> SchedulerDriver:
        if self.__driver is None:
            self.__driver = HpcPackDriver(config)
        return self.__driver

    @property
    def autoscale_home(self) -> str:
        if os.getenv("AUTOSCALE_HOME"):
            return os.environ["AUTOSCALE_HOME"]
        return "C:\\cycle\\jetpack\\config"

    @clilib.disablecommand
    def analyze(self, config: Dict, job_id: str, long: bool = False,) -> None:
        return super().analyze(config, job_id, long)


    @clilib.disablecommand
    def jobs(self, config: Dict) -> None:
        return super().jobs(config)

    @clilib.disablecommand
    def demand(
        self,
        config: Dict,
        output_columns: Optional[List[str]],
        output_format: OutputFormat,
        long: bool = False,
    ) -> None:
        return super().demand(config, output_columns, output_format, long)

    @clilib.disablecommand
    def shell(config: Dict, shell_locals: Dict[str, Any], script: Optional[str],) -> None:
        return super().shell(config, shell_locals, script)

    @clilib.disablecommand
    def join_nodes(
        self, config: Dict, hostnames: List[str], node_names: List[str]
    ) -> None:
        return super().join_nodes(config, hostnames, node_names)

    @clilib.disablecommand
    def remove_nodes(
        self,
        config: Dict,
        hostnames: List[str],
        node_names: List[str],
        force: bool = False,
    ) -> None:
        return super().remove_nodes(config, hostnames, node_names, force)

    def autoscale(
        self,
        config: Dict,
        output_columns: Optional[List[str]],
        output_format: OutputFormat,
        dry_run: bool = False,
        long: bool = False,
    ) -> None:
        """End-to-end autoscale process, including creation, deletion and joining of nodes."""
        output_columns = output_columns or self._get_default_output_columns(config)

        ctx_handler = self._ctx_handler(config)

        register_result_handler(ctx_handler)

        driver = self._driver(config)
        driver.initialize()

        config = driver.preprocess_config(config)

        logging.debug("Driver = %s", driver)

        return autoscale_hpcpack(config, ctx_handler=ctx_handler, dry_run=dry_run)

    def _initconfig(self, config: Dict) -> None:
        pass    

    def _initconfig_parser(self, parser: ArgumentParser) -> None:


        parser.add_argument(
            "--disable-autostart",
            required=False,
            action="store_false",
            default=True,
            dest="autoscale__start_enabled",
            help="Disable autoscaling"
        )

        parser.add_argument(
            "--vm_retention_days", default=7, type=int, dest="autoscale__vm_retention_days"
        )

        parser.add_argument(
            "--statefile", default="C:\\cycle\\jetpack\\config\\autoscaler_state.txt"
        )

        parser.add_argument(
            "--archivefile", default="C:\\cycle\\jetpack\\config\\autoscaler_archive.txt"
        )

        parser.add_argument(
            "--hpcpack-pem", default="C:\\cycle\\jetpack\\config\\hpc-comm.pem", dest="hpcpack__pem"
        )

        parser.add_argument(
            "--hn-hostname", default="localhost", dest="hpcpack__hn_hostname"
        )



        



    def _default_output_columns(
        self, config: Dict, cmd: Optional[str] = None
    ) -> List[str]:

        return config.get(
            "output_columns",
            [
                "name",
                "hostname",
                "state",
                "vm_size",
                "instance_id[:11]",
                "ctr@create_time_remaining",
                "itr@idle_time_remaining",
            ],
        )

    def _setup_shell_locals(self, config: Dict) -> Dict:
        """
        Provides read only interactive shell. type hpcpackhelp()
        in the shell for more information
        """
        ctx = DefaultContextHandler("[interactive-readonly]")

        def hpcpackhelp() -> None:
            print("config               - dict representing autoscale configuration.")
            print("cli                  - object representing the CLI commands")
            print(
                "node_mgr             - ScaleLib NodeManager - interacts with CycleCloud for all node related"
                + "                    activities - creation, deletion, limits, buckets etc."
            )
            print("hpcpackhelp            - This help function")

        shell_locals = {
            "config": config,
            "cli": self,
            "ctx": ctx,
            "node_mgr": new_node_manager(config),
            "hpcpackhelp": hpcpackhelp,
        }

        return shell_locals



def main(argv: Iterable[str] = None) -> None:
    hpcpack_cli = HpcPackCLI()
    clilib.main(argv or sys.argv[1:], "hpcpack", hpcpack_cli, default_config=os.path.join(hpcpack_cli.autoscale_home, "autoscale.json"))


if __name__ == "__main__":
    main()
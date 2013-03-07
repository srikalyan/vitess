package wrangler

import (
	"fmt"

	"code.google.com/p/vitess/go/relog"
	tm "code.google.com/p/vitess/go/vt/tabletmanager"
)

// Assume the master is dead and not coming back. Just push your way
// forward.  Force means we are reparenting to the same master
// (assuming the data has been externally synched).
func (wr *Wrangler) reparentShardBrutal(slaveTabletMap map[string]*tm.TabletInfo, failedMaster, masterElectTablet *tm.TabletInfo, leaveMasterReadOnly, force bool) error {
	relog.Info("Skipping ValidateShard - not a graceful situation")

	if _, ok := slaveTabletMap[masterElectTablet.Path()]; !ok && !force {
		return fmt.Errorf("master elect tablet not in replication graph %v %v %v", masterElectTablet.Path(), failedMaster.ShardPath(), mapKeys(slaveTabletMap))
	}

	// Check the master-elect and slaves are in good shape when the action
	// has not been forced.
	if !force {
		// Make sure all tablets have the right parent and reasonable positions.
		if err := wr.checkSlaveReplication(slaveTabletMap, tm.NO_TABLET); err != nil {
			return err
		}

		// Check the master-elect is fit for duty - call out for hardware checks.
		if err := wr.checkMasterElect(masterElectTablet); err != nil {
			return err
		}

		relog.Info("check slaves %v", masterElectTablet.ShardPath())
		restartableSlaveTabletMap := restartableTabletMap(slaveTabletMap)
		err := wr.checkSlaveConsistency(restartableSlaveTabletMap, nil)
		if err != nil {
			return err
		}
	} else {
		relog.Info("forcing reparent to same master %v", masterElectTablet.Path())
		err := wr.breakReplication(slaveTabletMap, masterElectTablet)
		if err != nil {
			return err
		}
	}

	rsd, err := wr.promoteSlave(masterElectTablet)
	if err != nil {
		// FIXME(msolomon) This suggests that the master-elect is dead.
		// We need to classify certain errors as temporary and retry.
		return fmt.Errorf("promote slave failed: %v %v", err, masterElectTablet.Path())
	}

	// Once the slave is promoted, remove it from our map
	delete(slaveTabletMap, masterElectTablet.Path())

	majorityRestart, restartSlaveErr := wr.restartSlaves(slaveTabletMap, rsd)

	if !force {
		relog.Info("scrap failed master %v", failedMaster.Path())
		// The master is dead so execute the action locally instead of
		// enqueing the scrap action for an arbitrary amount of time.
		if scrapErr := tm.Scrap(wr.zconn, failedMaster.Path(), false); scrapErr != nil {
			relog.Warning("scrapping failed master failed: %v", scrapErr)
		}
	}

	err = wr.finishReparent(masterElectTablet, majorityRestart, leaveMasterReadOnly)
	if err != nil {
		return err
	}

	if restartSlaveErr != nil {
		// This is more of a warning at this point.
		return restartSlaveErr
	}

	return nil
}